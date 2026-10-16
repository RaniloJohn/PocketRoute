import '../cli/session.dart';
import '../cli/switch_commands.dart';
import '../net/frames.dart';
import '../net/mac_address.dart';
import '../protocols/ip_stack.dart';
import '../protocols/mac_table.dart';
import '../sim/network.dart';

/// A layer 2 switch: Fast Ethernet access ports, Gigabit uplinks, and one
/// management interface (Vlan1). Every port is in VLAN 1 until VLANs land.
class L2Switch extends Device {
  L2Switch(
    super.id, {
    String? hostname,
    this.fastEthernetPorts = 24,
    this.gigabitPorts = 2,
  }) : super(hostname: hostname ?? defaultHostname);

  static const defaultHostname = 'Switch';
  static const managementVlan = 1;

  final int fastEthernetPorts;
  final int gigabitPorts;

  @override
  late final List<Port> ports = [
    for (var i = 1; i <= fastEthernetPorts; i++)
      Port(this, 'FastEthernet0/$i', 'Fa0/$i', i),
    for (var i = 1; i <= gigabitPorts; i++)
      Port(this, 'GigabitEthernet0/$i', 'Gi0/$i', fastEthernetPorts + i),
  ];

  late final MacTable macTable = MacTable(() => scheduler.now);

  /// Interface Vlan1 starts shut down, as on real switches.
  bool sviAdminUp = false;
  String? sviDescription;

  /// Saved by `copy running-config startup-config`; null until first save.
  String? startupConfig;

  late final IpStack svi = IpStack(
    scheduler: () => scheduler,
    mac: MacAddress.derived(id, 0),
    transmit: _sendFromSvi,
    isUp: () => sviIsUp,
    defaultTtl: 255,
    arpTimeout: 4 * 60 * 60 * 1000,
  );

  /// Vlan1 is up when enabled and at least one port in the VLAN is up.
  bool get sviIsUp => sviAdminUp && ports.any((p) => p.isUp);

  /// Opens a console session. [write] receives everything the CLI prints.
  CliSession openCli(void Function(String text) write) =>
      CliSession(switchCommands(this), hostname: () => hostname, write: write);

  @override
  void receive(Port port, Frame frame) {
    macTable.learn(frame.src, managementVlan, port);
    if (frame.dst == svi.mac) {
      if (sviIsUp) svi.receive(frame);
      return;
    }
    if (frame.dst.isGroup) {
      if (sviIsUp) svi.receive(frame);
      _flood(frame, except: port);
      return;
    }
    final out = macTable.lookup(frame.dst, managementVlan);
    if (out == null) {
      _flood(frame, except: port);
    } else if (!identical(out, port)) {
      out.send(frame);
    }
  }

  @override
  void portStateChanged(Port port) {
    if (!port.isUp) macTable.flushPort(port);
  }

  void _sendFromSvi(Frame frame) {
    final out = frame.dst.isGroup
        ? null
        : macTable.lookup(frame.dst, managementVlan);
    if (out == null) {
      _flood(frame);
    } else {
      out.send(frame);
    }
  }

  void _flood(Frame frame, {Port? except}) {
    for (final port in ports) {
      if (!identical(port, except) && port.isUp) port.send(frame);
    }
  }
}
