import '../net/frames.dart';
import '../protocols/ip_stack.dart';
import '../sim/network.dart';

/// How an end host is drawn; all behave the same on the network.
enum HostKind { pc, laptop, server }

/// An end host with one Ethernet port and an RS-232 port for console cables.
class Pc extends Device {
  Pc(super.id, {String? hostname, this.kind = HostKind.pc})
    : super(hostname: hostname ?? id);

  final HostKind kind;

  @override
  late final List<Port> ports = [Port(this, 'FastEthernet0', 'Fa0', 0)];

  @override
  late final List<Port> managementPorts = [
    Port(this, 'RS232', 'RS232', 200, medium: PortMedium.rs232),
  ];

  Port get nic => ports.first;

  Port get rs232 => managementPorts.single;

  /// The device whose console this host is cabled to, if any.
  Device? get consoleTarget => rs232.peer?.device;

  late final IpStack ip = IpStack(
    scheduler: () => scheduler,
    mac: nic.mac,
    transmit: nic.send,
    isUp: () => nic.isUp,
  );

  @override
  void receive(Port port, Frame frame) {
    if (frame.dst == nic.mac || frame.dst.isBroadcast) ip.receive(frame);
  }
}
