import '../cli/common_commands.dart';
import '../cli/router_commands.dart';
import '../cli/session.dart';
import '../net/frames.dart';
import '../net/ipv4.dart';
import '../protocols/echo.dart';
import '../protocols/ip_stack.dart';
import '../protocols/routing.dart';
import '../sim/network.dart';

export '../protocols/routing.dart' show Route, RouteSource, StaticRoute;

/// A routed interface: a physical port, or a dot1Q subinterface of one.
class RouterInterface implements L3Interface {
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

  @override
  late final IpStack stack = IpStack(
    scheduler: () => router.scheduler,
    mac: port.mac,
    transmit: _transmit,
    isUp: () => isUp,
    defaultTtl: 255,
    arpTimeout: 4 * 60 * 60 * 1000,
    onPacket: (packet) => router.routing.onPacket(this, packet),
  );

  bool get isMain => subId == null;

  @override
  String get name => isMain ? port.name : '${port.name}.$subId';

  @override
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
  @override
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

/// A router with Gigabit Ethernet and serial ports, connected and static
/// routing, and router-on-a-stick subinterfaces. Ports start shut down, as on
/// real routers.
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
    for (var i = 0; i < serialPortCount; i++)
      Port(
        this,
        'Serial0/0/$i',
        'S0/0/$i',
        100 + i,
        adminUp: false,
        medium: PortMedium.serial,
      ),
  ];

  static const serialPortCount = 2;

  @override
  late final List<Port> managementPorts = [
    Port(this, 'Console', 'Con', 200, medium: PortMedium.console),
  ];

  late final Map<Port, RouterInterface> _main = {
    for (final port in ports) port: RouterInterface._(this, port, null),
  };
  final _subs = <RouterInterface>[];

  late final RoutingEngine routing = RoutingEngine(
    interfaces: () => interfaces,
    scheduler: () => scheduler,
  );

  List<StaticRoute> get staticRoutes => routing.staticRoutes;

  List<Route> get routes => routing.routes;

  EchoClient get echo => routing.echo;

  Route? lookup(Ipv4Address dst) => routing.lookup(dst);

  /// Sends a packet this router originates. False if there is no route.
  bool originate(Ipv4Packet packet) => routing.originate(packet);

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
  RouterInterface? interface(String name) =>
      routing.interfaceNamed(name) as RouterInterface?;

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
}
