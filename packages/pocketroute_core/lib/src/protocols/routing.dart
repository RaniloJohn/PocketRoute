import '../net/frames.dart';
import '../net/ipv4.dart';
import '../sim/scheduler.dart';
import 'echo.dart';
import 'ip_stack.dart';

/// Anything with an IP address a routing engine can send through: a router
/// port or subinterface, a switch virtual interface, a routed switch port.
abstract interface class L3Interface {
  String get name;
  String get shortName;
  IpStack get stack;

  /// Line protocol up.
  bool get isUp;
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
  final L3Interface interface;
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

/// IPv4 routing for a device with several L3 interfaces (RFC 1812): the
/// routing table, longest-prefix forwarding, TTL, and ICMP errors.
///
/// With [forwarding] off (a switch without `ip routing`) the device still
/// answers and originates traffic, using [defaultGateway] for other subnets,
/// but never forwards packets between interfaces.
class RoutingEngine {
  RoutingEngine({
    required this._interfaces,
    required this._scheduler,
    this.forwarding = true,
  });

  final Iterable<L3Interface> Function() _interfaces;
  final Scheduler Function() _scheduler;
  bool forwarding;

  /// Used only while [forwarding] is off (`ip default-gateway`).
  Ipv4Address? defaultGateway;
  final staticRoutes = <StaticRoute>[];

  late final EchoClient echo = EchoClient(
    scheduler: _scheduler,
    send: originate,
    source: (dst) => lookup(dst)?.interface.stack.address ?? Ipv4Address.any,
  );

  Iterable<L3Interface> get interfaces => _interfaces();

  /// Finds an interface by full or short name, ignoring case.
  L3Interface? interfaceNamed(String name) {
    final wanted = name.toLowerCase();
    for (final iface in interfaces) {
      if (iface.name.toLowerCase() == wanted ||
          iface.shortName.toLowerCase() == wanted) {
        return iface;
      }
    }
    return null;
  }

  /// The routing table: connected and local routes of interfaces that are up,
  /// plus usable static routes (or, without forwarding, the default gateway).
  List<Route> get routes {
    final connected = <Route>[];
    for (final iface in interfaces) {
      final address = iface.stack.address, mask = iface.stack.mask;
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
    final configured = forwarding
        ? staticRoutes
        : [
            if (defaultGateway case final gateway?)
              StaticRoute(Ipv4Address.any, Ipv4Address.any, nextHop: gateway),
          ];
    final statics = <Route>[];
    for (final route in configured) {
      final L3Interface? via;
      if (route.exitInterface case final name?) {
        final iface = interfaceNamed(name);
        via = iface != null && iface.isUp && iface.stack.address != null
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

  bool isOwnAddress(Ipv4Address address) =>
      interfaces.any((i) => i.isUp && i.stack.address == address);

  /// Sends a packet this device originates. False if there is no route.
  bool originate(Ipv4Packet packet) {
    if (isOwnAddress(packet.dst)) {
      _scheduler().schedule(0, () => _deliverLocally(packet));
      return true;
    }
    final route = lookup(packet.dst);
    return route != null && _sendVia(route, packet);
  }

  /// Handles a packet that arrived on [ingress] addressed to its MAC.
  void onPacket(L3Interface ingress, Ipv4Packet packet) {
    if (isOwnAddress(packet.dst)) {
      _deliverLocally(packet);
      return;
    }
    if (!forwarding) return;
    final address = ingress.stack.address, mask = ingress.stack.mask;
    if (packet.dst == Ipv4Address.broadcast ||
        (address != null &&
            mask != null &&
            packet.dst == address.directedBroadcast(mask))) {
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

  void _sendError(Ipv4Packet original, IcmpErrorKind kind, L3Interface at) {
    // Never answer an ICMP error with another one (RFC 1812 4.3.2.7).
    if (original.body is IcmpError) return;
    final source = at.stack.address;
    if (source == null) return;
    originate(
      Ipv4Packet(
        src: source,
        dst: original.src,
        ttl: 255,
        body: IcmpError(kind, original),
      ),
    );
  }
}
