import '../net/frames.dart';
import '../net/ipv4.dart';
import '../sim/scheduler.dart';

enum PingStatus { reply, timeout, noRoute, unreachable, ttlExceeded }

/// The outcome of one echo request.
class PingResult {
  const PingResult(
    this.seq,
    this.status, {
    this.from,
    this.rtt,
    this.ttl,
    this.size = 0,
  });

  final int seq;
  final PingStatus status;

  /// Who answered: the target for replies, a router for ICMP errors.
  final Ipv4Address? from;

  /// Round-trip time in ticks (milliseconds) for anything that came back.
  final int? rtt;
  final int? ttl;
  final int size;

  bool get ok => status == PingStatus.reply;
}

/// Sends echo requests and matches the replies and ICMP errors that come
/// back. Hosts and routers each own one.
class EchoClient {
  EchoClient({
    required this._scheduler,
    required this._send,
    required this._source,
  });

  final Scheduler Function() _scheduler;

  /// Routes and transmits a packet; false if there is no route.
  final bool Function(Ipv4Packet packet) _send;

  /// Source address to use towards a destination.
  final Ipv4Address Function(Ipv4Address dst) _source;
  final _waiters = <(int, int), void Function(Ipv4Packet reply)>{};
  int _nextId = 1;

  /// Handles an echo reply, or an ICMP error quoting one of our requests.
  void handle(Ipv4Packet packet) {
    final echo = switch (packet.body) {
      IcmpEcho(isReply: true) && final echo => echo,
      IcmpError(
        original: Ipv4Packet(body: IcmpEcho(isReply: false) && final e),
      ) =>
        e,
      _ => null,
    };
    if (echo != null) _waiters[(echo.id, echo.seq)]?.call(packet);
  }

  /// Sends [count] echo requests, one after another: the next goes out
  /// [interval] ticks after an answer or timeout. [onResult] fires per
  /// request, then [onDone] once.
  void ping(
    Ipv4Address target, {
    int count = 4,
    int timeout = 1000,
    int interval = 0,
    int size = 32,
    int ttl = 128,
    required void Function(PingResult result) onResult,
    void Function()? onDone,
  }) {
    final id = _nextId++;
    final scheduler = _scheduler();

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
        _waiters.remove((id, seq));
        onResult(result);
        scheduler.schedule(interval, () => sendSeq(seq + 1));
      }

      _waiters[(id, seq)] = (answer) {
        final status = switch (answer.body) {
          IcmpError(kind: IcmpErrorKind.ttlExceeded) => PingStatus.ttlExceeded,
          IcmpError() => PingStatus.unreachable,
          IcmpEcho() => PingStatus.reply,
        };
        finish(
          PingResult(
            seq,
            status,
            from: answer.src,
            rtt: scheduler.now - sentAt,
            ttl: answer.ttl,
            size: size,
          ),
        );
      };
      final sent = _send(
        Ipv4Packet(
          src: _source(target),
          dst: target,
          ttl: ttl,
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
}
