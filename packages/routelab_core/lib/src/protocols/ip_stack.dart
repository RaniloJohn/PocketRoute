import '../net/frames.dart';
import '../net/ipv4.dart';
import '../net/mac_address.dart';
import '../sim/scheduler.dart';

enum PingStatus { reply, timeout, noRoute }

/// The outcome of one echo request.
class PingResult {
  const PingResult(this.seq, this.status, {this.rtt, this.ttl, this.size = 0});

  final int seq;
  final PingStatus status;

  /// Round-trip time in ticks (milliseconds); set for replies.
  final int? rtt;
  final int? ttl;
  final int size;

  bool get ok => status == PingStatus.reply;
}

/// A host's IPv4 layer on one interface: addressing, ARP (RFC 826) and ICMP
/// echo (RFC 792). Hosts do not forward; routers will add that later.
class IpStack {
  IpStack({
    required this._scheduler,
    required this.mac,
    required this.transmit,
    required this.isUp,
    this.defaultTtl = 128,
    this.arpTimeout = 120000,
  });

  final Scheduler Function() _scheduler;
  final MacAddress mac;

  /// Puts a frame on the wire (or into the switch fabric, for an SVI).
  final void Function(Frame frame) transmit;
  final bool Function() isUp;
  final int defaultTtl;

  /// Ticks an ARP entry stays valid.
  final int arpTimeout;

  /// Ticks to wait for an ARP reply before dropping queued packets.
  static const arpRequestTimeout = 1000;

  Ipv4Address? _address;
  Ipv4Address? _mask;
  Ipv4Address? gateway;
  final _arp = <Ipv4Address, (MacAddress, int)>{};
  final _pending = <Ipv4Address, List<Ipv4Packet>>{};
  final _echoWaiters = <(int, int), void Function(Ipv4Packet)>{};
  int _nextEchoId = 1;

  Scheduler get scheduler => _scheduler();

  Ipv4Address? get address => _address;

  Ipv4Address? get mask => _mask;

  bool get isConfigured => _address != null && _mask != null;

  /// Sets or (with nulls) clears the address. Flushes ARP state.
  void configure(Ipv4Address? address, Ipv4Address? mask) {
    _address = address;
    _mask = mask;
    clearArp();
  }

  void clearArp() {
    _arp.clear();
    _pending.clear();
  }

  /// Live ARP entries, sorted by address.
  Map<Ipv4Address, MacAddress> get arpEntries {
    final now = scheduler.now;
    _arp.removeWhere((_, entry) => now - entry.$2 > arpTimeout);
    final keys = _arp.keys.toList()..sort();
    return {for (final ip in keys) ip: _arp[ip]!.$1};
  }

  /// Handles a frame addressed to [mac] or broadcast.
  void receive(Frame frame) {
    if (!isConfigured) return;
    switch (frame.payload) {
      case final ArpPacket arp:
        _onArp(arp);
      case final Ipv4Packet packet:
        if (frame.dst == mac) _onIp(packet);
    }
  }

  /// Sends [packet], resolving the next hop with ARP first if needed.
  /// Returns false when there is no way to reach the destination.
  bool send(Ipv4Packet packet) {
    final address = _address, mask = _mask;
    if (address == null || mask == null || !isUp()) return false;
    if (packet.dst == address) {
      scheduler.schedule(0, () => _onIp(packet));
      return true;
    }
    final nextHop = packet.dst.sameSubnet(address, mask) ? packet.dst : gateway;
    if (nextHop == null) return false;
    final known = _lookup(nextHop);
    if (known != null) {
      transmit(Frame(src: mac, dst: known, payload: packet));
      return true;
    }
    final queued = _pending[nextHop];
    if (queued != null) {
      queued.add(packet);
      return true;
    }
    final waiting = _pending[nextHop] = [packet];
    transmit(
      Frame(
        src: mac,
        dst: MacAddress.broadcast,
        payload: ArpPacket(
          operation: ArpOperation.request,
          senderMac: mac,
          senderIp: address,
          targetMac: const MacAddress(0),
          targetIp: nextHop,
        ),
      ),
    );
    scheduler.schedule(arpRequestTimeout, () {
      if (identical(_pending[nextHop], waiting)) _pending.remove(nextHop);
    });
    return true;
  }

  /// Sends [count] echo requests, one after another: the next goes out
  /// [interval] ticks after a reply or timeout. [onResult] fires per request,
  /// then [onDone] once.
  void ping(
    Ipv4Address target, {
    int count = 4,
    int timeout = 1000,
    int interval = 0,
    int size = 32,
    required void Function(PingResult result) onResult,
    void Function()? onDone,
  }) {
    final id = _nextEchoId++;

    void sendSeq(int seq) {
      if (seq >= count) {
        onDone?.call();
        return;
      }
      final sentAt = scheduler.now;
      var settled = false;
      void finish(PingResult result) {
        if (settled) return;
        settled = true;
        _echoWaiters.remove((id, seq));
        onResult(result);
        scheduler.schedule(interval, () => sendSeq(seq + 1));
      }

      _echoWaiters[(id, seq)] = (reply) => finish(
        PingResult(
          seq,
          PingStatus.reply,
          rtt: scheduler.now - sentAt,
          ttl: reply.ttl,
          size: size,
        ),
      );
      final sent = send(
        Ipv4Packet(
          src: _address ?? Ipv4Address.any,
          dst: target,
          ttl: defaultTtl,
          body: IcmpEcho(isReply: false, id: id, seq: seq, size: size),
        ),
      );
      if (!sent) {
        finish(PingResult(seq, PingStatus.noRoute));
        return;
      }
      scheduler.schedule(
        timeout,
        () => finish(PingResult(seq, PingStatus.timeout)),
      );
    }

    sendSeq(0);
  }

  MacAddress? _lookup(Ipv4Address ip) {
    final entry = _arp[ip];
    if (entry == null) return null;
    if (scheduler.now - entry.$2 > arpTimeout) {
      _arp.remove(ip);
      return null;
    }
    return entry.$1;
  }

  void _onArp(ArpPacket arp) {
    final forUs = arp.targetIp == _address;
    // RFC 826: update an existing entry from any ARP; add one only if targeted.
    if (forUs || _arp.containsKey(arp.senderIp)) {
      _arp[arp.senderIp] = (arp.senderMac, scheduler.now);
      final queued = _pending.remove(arp.senderIp);
      for (final packet in queued ?? const <Ipv4Packet>[]) {
        transmit(Frame(src: mac, dst: arp.senderMac, payload: packet));
      }
    }
    if (forUs && arp.operation == ArpOperation.request) {
      transmit(
        Frame(
          src: mac,
          dst: arp.senderMac,
          payload: ArpPacket(
            operation: ArpOperation.reply,
            senderMac: mac,
            senderIp: _address!,
            targetMac: arp.senderMac,
            targetIp: arp.senderIp,
          ),
        ),
      );
    }
  }

  void _onIp(Ipv4Packet packet) {
    if (packet.dst != _address) return;
    switch (packet.body) {
      case IcmpEcho(isReply: false) && final echo:
        send(
          Ipv4Packet(
            src: _address!,
            dst: packet.src,
            ttl: defaultTtl,
            body: echo.toReply(),
          ),
        );
      case final IcmpEcho echo:
        _echoWaiters[(echo.id, echo.seq)]?.call(packet);
    }
  }
}
