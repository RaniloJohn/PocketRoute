import '../net/frames.dart';
import '../protocols/ip_stack.dart';
import '../sim/network.dart';

/// An end host with one Ethernet port.
class Pc extends Device {
  Pc(super.id, {String? hostname}) : super(hostname: hostname ?? id);

  @override
  late final List<Port> ports = [Port(this, 'FastEthernet0', 'Fa0', 0)];

  Port get nic => ports.single;

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
