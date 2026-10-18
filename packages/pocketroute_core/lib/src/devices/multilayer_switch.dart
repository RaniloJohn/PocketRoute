import '../net/frames.dart';
import '../protocols/ip_stack.dart';
import '../protocols/routing.dart';
import '../sim/network.dart';
import 'l2_switch.dart';

/// A switch port turned into a layer 3 interface with `no switchport`.
class RoutedPort implements L3Interface {
  RoutedPort._(this.sw, this.port);

  final MultilayerSwitch sw;
  final Port port;

  @override
  late final IpStack stack = IpStack(
    scheduler: () => sw.scheduler,
    mac: port.mac,
    transmit: port.send,
    isUp: () => isUp,
    defaultTtl: 255,
    arpTimeout: 4 * 60 * 60 * 1000,
    onPacket: (packet) => sw.routing.onPacket(this, packet),
  );

  @override
  String get name => port.name;

  @override
  String get shortName => port.shortName;

  @override
  bool get isUp => port.isUp;
}

/// A layer 3 (multilayer) switch: everything a layer 2 switch does, plus an
/// SVI per VLAN, routed ports, and IP routing between them once
/// `ip routing` is on.
class MultilayerSwitch extends L2Switch {
  MultilayerSwitch(super.id, {super.hostname, this.accessPorts = 24})
    : super(fastEthernetPorts: 0, gigabitPorts: 0);

  final int accessPorts;
  static const uplinkPorts = 4;

  @override
  List<Port> buildPorts() => [
    for (var i = 1; i <= accessPorts; i++)
      Port(this, 'GigabitEthernet1/0/$i', 'Gi1/0/$i', i),
    for (var i = 1; i <= uplinkPorts; i++)
      Port(this, 'GigabitEthernet1/1/$i', 'Gi1/1/$i', accessPorts + i),
  ];

  final _routed = <Port, RoutedPort>{};

  /// Forwarding stays off until `ip routing`.
  late final RoutingEngine routing = RoutingEngine(
    interfaces: () => interfaces,
    scheduler: () => scheduler,
    forwarding: false,
  );

  bool get ipRouting => routing.forwarding;

  set ipRouting(bool value) => routing.forwarding = value;

  /// Routed ports in port order, then SVIs in VLAN order.
  List<L3Interface> get interfaces => [
    for (final port in ports) ?_routed[port],
    ...svis.values,
  ];

  @override
  bool supportsSvi(int vlan) => true;

  @override
  void Function(Ipv4Packet packet)? packetHandlerFor(L3Interface iface) =>
      (packet) => routing.onPacket(iface, packet);

  @override
  bool isRouted(Port port) => _routed.containsKey(port);

  RoutedPort? routedPort(Port port) => _routed[port];

  /// Makes [port] a routed port (`no switchport`) or a switch port again.
  /// Either way its previous layer 2 or layer 3 settings are dropped.
  void setRouted(Port port, {required bool routed}) {
    if (routed == isRouted(port)) return;
    if (routed) {
      _routed[port] = RoutedPort._(this, port);
    } else {
      _routed.remove(port)?.stack.configure(null, null);
    }
    macTable.flushPort(port);
    portStateChanged(port);
  }

  @override
  void receiveRouted(Port port, Frame frame) {
    final routed = _routed[port];
    if (routed == null || frame.vlan != null) return;
    if (frame.dst == port.mac || frame.dst.isBroadcast) {
      routed.stack.receive(frame);
    }
  }

  @override
  void portStateChanged(Port port) {
    super.portStateChanged(port);
    if (!port.isUp) _routed[port]?.stack.clearArp();
  }
}
