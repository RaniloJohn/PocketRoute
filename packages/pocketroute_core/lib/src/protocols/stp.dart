import '../net/frames.dart';
import '../net/mac_address.dart';
import '../sim/network.dart';
import '../sim/scheduler.dart';

enum StpRole { root, designated, alternate, disabled }

enum StpState { blocking, listening, learning, forwarding, disabled }

/// A spanning tree priority vector; lower wins (IEEE 802.1D 8.6).
typedef _Vector = (BridgeId root, int cost, BridgeId bridge, (int, int) port);

int _compareVectors(_Vector a, _Vector b) {
  var c = a.$1.compareTo(b.$1);
  if (c != 0) return c;
  c = a.$2.compareTo(b.$2);
  if (c != 0) return c;
  c = a.$3.compareTo(b.$3);
  if (c != 0) return c;
  c = a.$4.$1.compareTo(b.$4.$1);
  return c != 0 ? c : a.$4.$2.compareTo(b.$4.$2);
}

class _PortInfo {
  StpRole role = StpRole.disabled;
  StpState state = StpState.disabled;

  /// Best BPDU heard on this port and when.
  Bpdu? heard;
  int heardAt = 0;

  /// Bumped on every role change so stale transition timers do nothing.
  int generation = 0;
}

/// IEEE 802.1D spanning tree, one instance for all VLANs.
///
/// Simplifications: every bridge sends hellos on its designated ports (as
/// RSTP does) rather than relaying the root's, and timers are shortened so
/// a port forwards a few seconds after coming up instead of 30.
class SpanningTree {
  SpanningTree({
    required this.ports,
    required this.bridgeMac,
    required this._scheduler,
    required this._sendBpdu,
    required this._flushAddresses,
    this._participates,
  });

  // Shortened timers, in ticks (ms). Standard values are 2 s, 20 s and 15 s.
  static const helloTime = 1000, maxAge = 6000, forwardDelay = 2000;
  static const defaultPriority = 32768;
  static const portPriority = 128;

  /// IEEE 802.1D-1998 short path costs.
  static int costFor(Port port) =>
      port.name.startsWith('GigabitEthernet') ? 4 : 19;

  final List<Port> ports;
  final MacAddress bridgeMac;
  final Scheduler Function() _scheduler;
  final void Function(Port port, Bpdu bpdu) _sendBpdu;
  final void Function() _flushAddresses;

  /// Ports that take part in spanning tree; routed ports do not.
  final bool Function(Port port)? _participates;

  bool _active(Port port) => port.isUp && (_participates?.call(port) ?? true);

  final _info = <Port, _PortInfo>{};
  final portfast = <Port>{};
  int _priority = defaultPriority;
  bool _helloRunning = false;
  int _topologyChangeUntil = -1;

  late BridgeId _rootId = bridgeId;
  int _rootCost = 0;
  Port? _rootPort;

  /// Priority as configured, a multiple of 4096. The bridge ID adds the
  /// VLAN number (1) as the extended system ID.
  int get priority => _priority;

  set priority(int value) {
    _priority = value;
    _recompute();
  }

  BridgeId get bridgeId => BridgeId(_priority + 1, bridgeMac);

  BridgeId get rootId => _rootId;

  int get rootCost => _rootCost;

  Port? get rootPort => _rootPort;

  bool get isRoot => _rootPort == null;

  Scheduler get _clock => _scheduler();

  StpRole role(Port port) => _portInfo(port).role;

  StpState state(Port port) => _portInfo(port).state;

  /// Data frames received on [port] may update the MAC table.
  bool learns(Port port) =>
      state(port) == StpState.learning || state(port) == StpState.forwarding;

  /// Data frames may enter and leave through [port].
  bool forwards(Port port) => state(port) == StpState.forwarding;

  void receive(Port port, Bpdu bpdu) {
    _portInfo(port)
      ..heard = bpdu
      ..heardAt = _clock.now;
    if (bpdu.topologyChange && identical(port, _rootPort)) {
      _flushAddresses();
      if (_clock.now >= _topologyChangeUntil) {
        _topologyChangeUntil = _clock.now + maxAge + forwardDelay;
      }
    }
    _recompute();
  }

  /// A port was cabled, uncabled, enabled or disabled.
  void portChanged(Port port) {
    if (!port.isUp) _portInfo(port).heard = null;
    _ensureHello();
    _recompute();
  }

  _PortInfo _portInfo(Port port) => _info.putIfAbsent(port, _PortInfo.new);

  (int, int) _portId(Port port) => (portPriority, port.index);

  void _ensureHello() {
    if (_helloRunning) return;
    _helloRunning = true;
    void tick() {
      _expireStale();
      _sendHellos();
      _clock.schedule(helloTime, tick, background: true);
    }

    _clock.schedule(helloTime, tick, background: true);
  }

  void _expireStale() {
    var changed = false;
    for (final info in _info.values) {
      if (info.heard != null && _clock.now - info.heardAt > maxAge) {
        info.heard = null;
        changed = true;
      }
    }
    if (changed) _recompute();
  }

  void _sendHellos() {
    for (final port in ports) {
      if (_active(port) && role(port) == StpRole.designated) {
        _sendBpdu(port, _bpduFor(port));
      }
    }
  }

  Bpdu _bpduFor(Port port) => Bpdu(
    rootId: _rootId,
    rootCost: _rootCost,
    bridgeId: bridgeId,
    portId: _portId(port),
    topologyChange: _clock.now < _topologyChangeUntil,
  );

  void _recompute() {
    final me = bridgeId;
    _Vector best = (me, 0, me, (0, 0));
    Port? bestPort;
    for (final port in ports) {
      final heard = _info[port]?.heard;
      if (heard == null || !_active(port)) continue;
      final _Vector offer = (
        heard.rootId,
        heard.rootCost + costFor(port),
        heard.bridgeId,
        heard.portId,
      );
      // Ties on everything heard fall to the lower receiving port.
      final cmp = _compareVectors(offer, best);
      if (cmp < 0 ||
          (cmp == 0 && bestPort != null && port.index < bestPort.index)) {
        best = offer;
        bestPort = port;
      }
    }
    // Information claiming a root worse than ourselves is ignored.
    if (bestPort != null && best.$1.compareTo(me) >= 0) {
      best = (me, 0, me, (0, 0));
      bestPort = null;
    }

    final rootChanged =
        best.$1 != _rootId || best.$2 != _rootCost || bestPort != _rootPort;
    _rootId = best.$1;
    _rootCost = best.$2;
    _rootPort = bestPort;

    var newlyDesignated = false;
    for (final port in ports) {
      final StpRole role;
      if (!_active(port)) {
        role = StpRole.disabled;
      } else if (identical(port, bestPort)) {
        role = StpRole.root;
      } else {
        final heard = _info[port]?.heard;
        final _Vector mine = (_rootId, _rootCost, me, _portId(port));
        final designated =
            heard == null ||
            _compareVectors(mine, (
                  heard.rootId,
                  heard.rootCost,
                  heard.bridgeId,
                  heard.portId,
                )) <
                0;
        role = designated ? StpRole.designated : StpRole.alternate;
      }
      if (_setRole(port, role) && role == StpRole.designated) {
        newlyDesignated = true;
      }
    }
    if (rootChanged || newlyDesignated) _sendHellos();
  }

  /// Returns true if the role changed.
  bool _setRole(Port port, StpRole role) {
    final info = _portInfo(port);
    if (info.role == role) return false;
    info
      ..role = role
      ..generation += 1;
    switch (role) {
      case StpRole.disabled:
        _setState(port, StpState.disabled);
      case StpRole.alternate:
        _setState(port, StpState.blocking);
      case StpRole.root || StpRole.designated:
        if (info.state == StpState.forwarding) break;
        if (portfast.contains(port) && role == StpRole.designated) {
          _setState(port, StpState.forwarding);
          break;
        }
        _setState(port, StpState.listening);
        final generation = info.generation;
        _clock.schedule(forwardDelay, () {
          if (info.generation != generation) return;
          _setState(port, StpState.learning);
          _clock.schedule(forwardDelay, () {
            if (info.generation == generation) {
              _setState(port, StpState.forwarding);
            }
          });
        });
    }
    return true;
  }

  void _setState(Port port, StpState state) {
    final info = _portInfo(port);
    final wasForwarding = info.state == StpState.forwarding;
    info.state = state;
    final isForwarding = state == StpState.forwarding;
    // Edge (portfast) ports do not signal a topology change.
    if (wasForwarding != isForwarding && !portfast.contains(port)) {
      _flushAddresses();
      _topologyChangeUntil = _clock.now + maxAge + forwardDelay;
    }
  }
}
