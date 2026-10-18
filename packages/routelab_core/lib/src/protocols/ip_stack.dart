import '../net/frames.dart';
import '../net/ipv4.dart';
import '../net/mac_address.dart';
import '../sim/scheduler.dart';
import 'echo.dart';

export 'echo.dart' show PingResult, PingStatus;

/// IPv4 on one interface: addressing and ARP (RFC 826). On its own it acts as
/// a host (default gateway, answering pings). A router sets [onPacket] to take
/// over every received packet and sends through [sendTo] itself.
class IpStack {
  IpStack({
    required this._scheduler,
    required this.mac,
    required this.transmit,
    required this.isUp,
    this.defaultTtl = 128,
    this.arpTimeout = 120000,
    this.onPacket,
  });

  final Scheduler Function() _scheduler;
  final MacAddress mac;

  /// Puts a frame on the wire (or into the switch fabric, for an SVI).
  final void Function(Frame frame) transmit;
  final bool Function() isUp;
  final int defaultTtl;

  /// Ticks an ARP entry stays valid.
  final int arpTimeout;

  /// Takes over received IPv4 packets (routers). Null: behave as a host.
  final void Function(Ipv4Packet packet)? onPacket;

  /// Ticks to wait for an ARP reply before dropping queued packets.
  static const arpRequestTimeout = 1000;

  Ipv4Address? _address;
  Ipv4Address? _mask;
  Ipv4Address? gateway;
  final _arp = <Ipv4Address, (MacAddress, int)>{};
  final _pending = <Ipv4Address, List<Ipv4Packet>>{};

  late final EchoClient echo = EchoClient(
    scheduler: _scheduler,
    send: send,
    source: (_) => _address ?? Ipv4Address.any,
  );

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

  /// Live ARP entries as (address, MAC, age in ticks), sorted by address.
  List<(Ipv4Address, MacAddress, int)> get arpTable => [
    for (final MapEntry(key: ip, value: mac) in arpEntries.entries)
      (ip, mac, scheduler.now - _arp[ip]!.$2),
  ];

  /// Handles a frame addressed to [mac] or broadcast.
  void receive(Frame frame) {
    if (!isConfigured) return;
    switch (frame.payload) {
      case final ArpPacket arp:
        _onArp(arp);
      case final Ipv4Packet packet when frame.dst == mac:
        final handler = onPacket;
        if (handler != null) {
          handler(packet);
        } else {
          _onHostPacket(packet);
        }
      default:
        break;
    }
  }

  /// Sends [packet] as a host: directly on the local subnet, otherwise via
  /// [gateway]. False when there is no way to reach the destination.
  bool send(Ipv4Packet packet) {
    final address = _address, mask = _mask;
    if (address == null || mask == null || !isUp()) return false;
    if (packet.dst == address) {
      scheduler.schedule(0, () => _onHostPacket(packet));
      return true;
    }
    final nextHop = packet.dst.sameSubnet(address, mask) ? packet.dst : gateway;
    return nextHop != null && sendTo(nextHop, packet);
  }

  /// Sends [packet] to the neighbour at [nextHop], resolving it with ARP
  /// first if needed. Packets wait up to [arpRequestTimeout] for the reply.
  bool sendTo(Ipv4Address nextHop, Ipv4Packet packet) {
    final address = _address;
    if (address == null || !isUp()) return false;
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

  /// Pings [target] as a host. See [EchoClient.ping].
  void ping(
    Ipv4Address target, {
    int count = 4,
    int timeout = 1000,
    int interval = 0,
    int size = 32,
    int? ttl,
    required void Function(PingResult result) onResult,
    void Function()? onDone,
  }) => echo.ping(
    target,
    count: count,
    timeout: timeout,
    interval: interval,
    size: size,
    ttl: ttl ?? defaultTtl,
    onResult: onResult,
    onDone: onDone,
  );

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

  void _onHostPacket(Ipv4Packet packet) {
    if (packet.dst != _address) return;
    switch (packet.body) {
      case IcmpEcho(isReply: false) && final request:
        send(
          Ipv4Packet(
            src: _address!,
            dst: packet.src,
            ttl: defaultTtl,
            body: request.toReply(),
          ),
        );
      default:
        echo.handle(packet);
    }
  }
}
