import '../cli/common_commands.dart';
import '../cli/router_commands.dart';
import '../cli/session.dart';
import '../net/frames.dart';
import '../net/ipv4.dart';
import '../protocols/echo.dart';
import '../protocols/ip_stack.dart';
import '../sim/network.dart';

/// A routed interface: a physical port, or a dot1Q subinterface of one.
class RouterInterface {
  RouterInterface._(this.router, this.port, this.subId);

  final Router router;
  final Port port;

  /// Subinterface number (`.10`), or null for the physical interface.
  final int? subId;

  /// 802.1Q VLAN this subinterface sends and receives; null until set.
  int? dot1qVlan;

  /// Frames for [dot1qVlan] travel untagged (the trunk's native VLAN).
  bool native = false;
  String? description;
  bool _subAdminUp = true;

  late final IpStack stack = IpStack(
    scheduler: () => router.scheduler,
    mac: port.mac,
    transmit: _transmit,
    isUp: () => isUp,
    defaultTtl: 255,
    arpTimeout: 4 * 60 * 60 * 1000,
    onPacket: (packet) => router._onPacket(this, packet),
  );

  bool get isMain => subId == null;

  String get name => isMain ? port.name : '${port.name}.$subId';

  String get shortName => isMain ? port.shortName : '${port.shortName}.$subId';

  bool get adminUp => isMain ? port.adminUp : _subAdminUp;

  set adminUp(bool value) {
    if (isMain) {
      port.adminUp = value;
    } else {
      _subAdminUp = value;
    }
    if (!isUp) stack.clearArp();
  }

  /// Line protocol: the port is up (which needs the physical interface
  /// enabled) and, for a subinterface, the subinterface is enabled too.
  bool get isUp => port.isUp && adminUp;

  Ipv4Address? get address => stack.address;

  Ipv4Address? get mask => stack.mask;

  void _transmit(Frame frame) {
    if (isMain || native) {
      port.send(frame);
    } else if (dot1qVlan case final vlan?) {
      port.send(frame.withVlan(vlan));
    }
  }
}

enum RouteSource { connected, local, static }

/// An entry in the routing table.
class Route {
  const Route(
    this.source,
    this.network,
    this.mask,
    this.interface, {
    this.nextHop,
  });

  final RouteSource source;
  final Ipv4Address network;
  final Ipv4Address mask;
  final RouterInterface interface;
  final Ipv4Address? nextHop;

  int get prefixLength => mask.prefixLength!;

  /// Administrative distance: connected 0, static 1.
  int get distance => source == RouteSource.static ? 1 : 0;

  bool contains(Ipv4Address address) => address.network(mask) == network;
}

/// A configured `ip route`. It is installed only while it can be used.
class StaticRoute {
  const StaticRoute(this.network, this.mask, {this.nextHop, this.exitInterface})
    : assert(nextHop != null || exitInterface != null);

  final Ipv4Address network;
  final Ipv4Address mask;
  final Ipv4Address? nextHop;

  /// Interface name, kept as text so the route survives the interface being
  /// deleted and recreated.
  final String? exitInterface;

  @override
  bool operator ==(Object other) =>
      other is StaticRoute &&
      other.network == network &&
      other.mask == mask &&
      other.nextHop == nextHop &&
      other.exitInterface == exitInterface;

  @override
  int get hashCode => Object.hash(network, mask, nextHop, exitInterface);
}

/// A router with Gigabit Ethernet ports, connected and static routing, and
/// router-on-a-stick subinterfaces. Ports start shut down, as on real routers.
class Router extends Device implements ConfigurableDevice {
  Router(super.id, {String? hostname, this.portCount = 4})
    : super(hostname: hostname ?? 'Router');

  final int portCount;

  @override
  String get defaultHostname => 'Router';

  @override
  String? startupConfig;

  @override
  late final List<Port> ports = [
    for (var i = 0; i < portCount; i++)
      Port(this, 'GigabitEthernet0/$i', 'Gi0/$i', i, adminUp: false),
  ];

  late final Map<Port, RouterInterface> _main = {
    for (final port in ports) port: RouterInterface._(this, port, null),
  };
  final _subs = <RouterInterface>[];
  final staticRoutes = <StaticRoute>[];

  late final EchoClient echo = EchoClient(
    scheduler: () => scheduler,
    send: originate,
    source: (dst) => lookup(dst)?.interface.address ?? Ipv4Address.any,
  );

  /// Physical interfaces in port order, each followed by its subinterfaces.
  List<RouterInterface> get interfaces => [
    for (final port in ports) ...[
      _main[port]!,
      ...(_subs.where((s) => identical(s.port, port)).toList()
        ..sort((a, b) => a.subId!.compareTo(b.subId!))),
    ],
  ];

  RouterInterface mainInterface(Port port) => _main[port]!;

  /// Finds an interface by full or short name, e.g. `Gi0/0.10`.
  RouterInterface? interface(String name) {
    final wanted = name.toLowerCase();
    for (final iface in interfaces) {
      if (iface.name.toLowerCase() == wanted ||
          iface.shortName.toLowerCase() == wanted) {
        return iface;
      }
    }
    return null;
  }

  RouterInterface subinterface(Port port, int subId) {
    for (final sub in _subs) {
      if (identical(sub.port, port) && sub.subId == subId) return sub;
    }
    final sub = RouterInterface._(this, port, subId);
    _subs.add(sub);
    return sub;
  }

  void removeSubinterface(RouterInterface sub) {
    sub.stack.configure(null, null);
    _subs.remove(sub);
  }

  /// Interfaces back to defaults before a saved configuration is replayed.
  /// Saved configs only mention `shutdown` for disabled ports.
  @override
  void prepareForConfigLoad() {
    for (final port in ports) {
      port.adminUp = true;
    }
  }

  @override
  String renderConfig() => renderRouterConfig(this);

  /// Opens a console session. [write] receives everything the CLI prints.
  @override
  CliSession openCli(void Function(String text) write) =>
      CliSession(routerCommands(this), hostname: () => hostname, write: write);

  /// The routing table: connected and local routes of interfaces that are up,
  /// plus static routes whose next hop or exit interface is usable.
  List<Route> get routes {
    final connected = <Route>[];
    for (final iface in interfaces) {
      final address = iface.address, mask = iface.mask;
      if (!iface.isUp || address == null || mask == null) continue;
      connected
        ..add(Route(RouteSource.connected, address.network(mask), mask, iface))
        ..add(
          Route(
            RouteSource.local,
            address,
            Ipv4Address.maskOfLength(32),
            iface,
          ),
        );
    }
    final statics = <Route>[];
    for (final route in staticRoutes) {
      final RouterInterface? via;
      if (route.exitInterface case final name?) {
        final iface = interface(name);
        via = iface != null && iface.isUp && iface.address != null
            ? iface
            : null;
      } else {
        via = _longestMatch(connected, route.nextHop!)?.interface;
      }
      if (via != null) {
        statics.add(
          Route(
            RouteSource.static,
            route.network,
            route.mask,
            via,
            nextHop: route.nextHop,
          ),
        );
      }
    }
    return [...connected, ...statics];
  }

  /// Best route to [dst]: longest prefix, then lowest distance.
  Route? lookup(Ipv4Address dst) => _longestMatch(routes, dst);

  static Route? _longestMatch(List<Route> table, Ipv4Address dst) {
    Route? best;
    for (final route in table) {
      if (!route.contains(dst)) continue;
      if (best == null ||
          route.prefixLength > best.prefixLength ||
          (route.prefixLength == best.prefixLength &&
              route.distance < best.distance)) {
        best = route;
      }
    }
    return best;
  }

  @override
  void receive(Port port, Frame frame) {
    final iface = _interfaceFor(port, frame.vlan);
    if (iface == null || !iface.isUp) return;
    iface.stack.receive(frame.withVlan(null));
  }

  @override
  void portStateChanged(Port port) {
    if (port.isUp) return;
    for (final iface in interfaces) {
      if (identical(iface.port, port)) iface.stack.clearArp();
    }
  }

  /// Sends a packet this router originates. False if there is no route.
  bool originate(Ipv4Packet packet) {
    if (_isOwnAddress(packet.dst)) {
      scheduler.schedule(0, () => _deliverLocally(packet));
      return true;
    }
    final route = lookup(packet.dst);
    return route != null && _sendVia(route, packet);
  }

  RouterInterface? _interfaceFor(Port port, int? vlan) {
    final subs = _subs.where((s) => identical(s.port, port));
    if (vlan == null) {
      for (final sub in subs) {
        if (sub.native && sub.dot1qVlan != null) return sub;
      }
      return _main[port];
    }
    for (final sub in subs) {
      if (sub.dot1qVlan == vlan && !sub.native) return sub;
    }
    return null;
  }

  bool _isOwnAddress(Ipv4Address address) =>
      interfaces.any((i) => i.isUp && i.address == address);

  void _onPacket(RouterInterface ingress, Ipv4Packet packet) {
    if (_isOwnAddress(packet.dst)) {
      _deliverLocally(packet);
      return;
    }
    if (packet.dst == Ipv4Address.broadcast ||
        packet.dst == ingress.address!.directedBroadcast(ingress.mask!)) {
      return;
    }
    if (packet.ttl <= 1) {
      _sendError(packet, IcmpErrorKind.ttlExceeded, ingress);
      return;
    }
    final route = lookup(packet.dst);
    if (route == null) {
      _sendError(packet, IcmpErrorKind.netUnreachable, ingress);
      return;
    }
    _sendVia(route, packet.withTtl(packet.ttl - 1));
  }

  bool _sendVia(Route route, Ipv4Packet packet) =>
      route.interface.stack.sendTo(route.nextHop ?? packet.dst, packet);

  void _deliverLocally(Ipv4Packet packet) {
    switch (packet.body) {
      case IcmpEcho(isReply: false) && final request:
        originate(
          Ipv4Packet(
            src: packet.dst,
            dst: packet.src,
            ttl: 255,
            body: request.toReply(),
          ),
        );
      default:
        echo.handle(packet);
    }
  }

  void _sendError(Ipv4Packet original, IcmpErrorKind kind, RouterInterface at) {
    // Never answer an ICMP error with another one (RFC 1812 4.3.2.7).
    if (original.body is IcmpError) return;
    originate(
      Ipv4Packet(
        src: at.address!,
        dst: original.src,
        ttl: 255,
        body: IcmpError(kind, original),
      ),
    );
  }
}
