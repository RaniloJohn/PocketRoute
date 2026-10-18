import 'dart:collection';

import '../cli/common_commands.dart';
import '../cli/session.dart';
import '../cli/switch_commands.dart';
import '../net/frames.dart';
import '../net/mac_address.dart';
import '../protocols/ip_stack.dart';
import '../protocols/mac_table.dart';
import '../protocols/stp.dart';
import '../protocols/vlan.dart';
import '../sim/network.dart';

enum SwitchportMode { access, trunk }

/// Layer 2 settings of one switch port.
class SwitchportConfig {
  SwitchportMode mode = SwitchportMode.access;
  int accessVlan = 1;

  /// Trunk VLAN sent and received untagged (IEEE 802.1Q native VLAN).
  int nativeVlan = 1;
  VlanSet allowed = VlanSet.all();

  bool get isTrunk => mode == SwitchportMode.trunk;

  /// Whether this port belongs to [vlan] in its current mode.
  bool carries(int vlan) =>
      isTrunk ? allowed.contains(vlan) : accessVlan == vlan;
}

/// A layer 2 switch: Fast Ethernet access ports, Gigabit uplinks, VLANs with
/// 802.1Q trunks, spanning tree, and one management interface (Vlan1).
class L2Switch extends Device implements ConfigurableDevice {
  L2Switch(
    super.id, {
    String? hostname,
    this.fastEthernetPorts = 24,
    this.gigabitPorts = 2,
  }) : super(hostname: hostname ?? 'Switch');

  static const managementVlan = 1;

  final int fastEthernetPorts;
  final int gigabitPorts;

  @override
  String get defaultHostname => 'Switch';

  @override
  String? startupConfig;

  @override
  late final List<Port> ports = [
    for (var i = 1; i <= fastEthernetPorts; i++)
      Port(this, 'FastEthernet0/$i', 'Fa0/$i', i),
    for (var i = 1; i <= gigabitPorts; i++)
      Port(this, 'GigabitEthernet0/$i', 'Gi0/$i', fastEthernetPorts + i),
  ];

  @override
  late final List<Port> managementPorts = [
    Port(this, 'Console', 'Con', 200, medium: PortMedium.console),
  ];

  @override
  bool get isSwitchLike => true;

  /// VLAN database: ID -> name. VLAN 1 always exists.
  final vlans = SplayTreeMap<int, String>.of({1: 'default'});

  late final Map<Port, SwitchportConfig> _switchport = {
    for (final port in ports) port: SwitchportConfig(),
  };

  late final MacTable macTable = MacTable(() => scheduler.now);

  late final SpanningTree stp = SpanningTree(
    ports: ports,
    bridgeMac: MacAddress.derived(id, 0),
    scheduler: () => scheduler,
    sendBpdu: (port, bpdu) =>
        port.send(Frame(src: port.mac, dst: Bpdu.groupAddress, payload: bpdu)),
    flushAddresses: () => macTable.clear(),
  );

  /// Interface Vlan1 starts shut down, as on real switches.
  bool sviAdminUp = false;
  String? sviDescription;

  late final IpStack svi = IpStack(
    scheduler: () => scheduler,
    mac: MacAddress.derived(id, 0),
    transmit: _sendFromSvi,
    isUp: () => sviIsUp,
    defaultTtl: 255,
    arpTimeout: 4 * 60 * 60 * 1000,
  );

  SwitchportConfig switchport(Port port) => _switchport[port]!;

  /// Default name for a new VLAN, e.g. `VLAN0010`.
  static String defaultVlanName(int vlan) =>
      'VLAN${vlan.toString().padLeft(4, '0')}';

  void createVlan(int vlan, {String? name}) {
    vlans[vlan] = name ?? vlans[vlan] ?? defaultVlanName(vlan);
  }

  void deleteVlan(int vlan) {
    if (vlan == 1) throw ArgumentError('VLAN 1 cannot be deleted');
    vlans.remove(vlan);
    macTable.clear();
  }

  /// Vlan1 is up when enabled and a forwarding port carries VLAN 1.
  bool get sviIsUp =>
      sviAdminUp &&
      ports.any(
        (p) =>
            p.isUp && switchport(p).carries(managementVlan) && stp.forwards(p),
      );

  @override
  String renderConfig() => renderSwitchConfig(this);

  /// Switch defaults already match what a saved config leaves unsaid.
  @override
  void prepareForConfigLoad() {}

  /// Opens a console session. [write] receives everything the CLI prints.
  @override
  CliSession openCli(void Function(String text) write) =>
      CliSession(switchCommands(this), hostname: () => hostname, write: write);

  @override
  void receive(Port port, Frame frame) {
    if (frame.payload case final Bpdu bpdu) {
      stp.receive(port, bpdu);
      return;
    }
    final vlan = _ingressVlan(port, frame);
    if (vlan == null || !stp.learns(port)) return;
    macTable.learn(frame.src, vlan, port);
    if (!stp.forwards(port)) return;

    final untagged = frame.withVlan(null);
    final forSvi = vlan == managementVlan && sviIsUp;
    if (frame.dst == svi.mac) {
      if (forSvi) svi.receive(untagged);
      return;
    }
    if (frame.dst.isGroup) {
      if (forSvi) svi.receive(untagged);
      _flood(untagged, vlan, except: port);
      return;
    }
    final out = macTable.lookup(frame.dst, vlan);
    if (out == null) {
      _flood(untagged, vlan, except: port);
    } else if (!identical(out, port)) {
      _egress(out, untagged, vlan);
    }
  }

  @override
  void portStateChanged(Port port) {
    if (!port.isUp) macTable.flushPort(port);
    stp.portChanged(port);
  }

  /// The VLAN a received frame belongs to, or null to drop it.
  int? _ingressVlan(Port port, Frame frame) {
    final config = switchport(port);
    final int vlan;
    if (config.isTrunk) {
      vlan = frame.vlan ?? config.nativeVlan;
      if (!config.allowed.contains(vlan)) return null;
    } else {
      // Access ports drop tagged frames.
      if (frame.vlan != null) return null;
      vlan = config.accessVlan;
    }
    return vlans.containsKey(vlan) ? vlan : null;
  }

  /// Sends an untagged [frame] in [vlan] out of [port], tagging it on trunks.
  void _egress(Port port, Frame frame, int vlan) {
    final config = switchport(port);
    if (!config.carries(vlan) || !stp.forwards(port)) return;
    port.send(
      config.isTrunk && vlan != config.nativeVlan
          ? frame.withVlan(vlan)
          : frame,
    );
  }

  void _flood(Frame frame, int vlan, {Port? except}) {
    for (final port in ports) {
      if (!identical(port, except) && port.isUp) _egress(port, frame, vlan);
    }
  }

  void _sendFromSvi(Frame frame) {
    final out = frame.dst.isGroup
        ? null
        : macTable.lookup(frame.dst, managementVlan);
    if (out == null) {
      _flood(frame, managementVlan);
    } else {
      _egress(out, frame, managementVlan);
    }
  }
}
