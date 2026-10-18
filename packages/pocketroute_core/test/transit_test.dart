import 'package:pocketroute_core/pocketroute_core.dart';
import 'package:test/test.dart';

import 'support/terminals.dart';

void main() {
  test('every frame on a cable is reported with a readable description', () {
    final net = Network();
    final sw = net.add(L2Switch('sw'));
    final a = net.add(Pc('a'));
    final b = net.add(Pc('b'));
    net
      ..connect(a.nic, sw.port('Fa0/1')!)
      ..connect(b.nic, sw.port('Fa0/2')!)
      ..scheduler.runUntilIdle();
    PcTerminal(a).run('ipconfig 10.0.0.1 255.255.255.0');
    PcTerminal(b).run('ipconfig 10.0.0.2 255.255.255.0');

    final seen = <Transit>[];
    net.onTransmit = seen.add;
    PcTerminal(a).run('ping -n 1 10.0.0.2');
    net.scheduler.runUntilIdle();

    final traffic = seen.where((t) => t.kind != FrameKind.stp).toList();
    expect(traffic.map((t) => t.description), [
      'ARP request: who has 10.0.0.2? Tell 10.0.0.1', // PC a -> switch
      'ARP request: who has 10.0.0.2? Tell 10.0.0.1', // flooded to b
      'ARP reply: 10.0.0.2 is at ${b.nic.mac.toDotted()}',
      'ARP reply: 10.0.0.2 is at ${b.nic.mac.toDotted()}',
      'ICMP echo request 10.0.0.1 to 10.0.0.2, TTL 128',
      'ICMP echo request 10.0.0.1 to 10.0.0.2, TTL 128',
      'ICMP echo reply 10.0.0.2 to 10.0.0.1, TTL 128',
      'ICMP echo reply 10.0.0.2 to 10.0.0.1, TTL 128',
    ]);
    expect(traffic.first.from, same(a.nic));
    expect(traffic.first.arrivesAt, traffic.first.sentAt + net.linkDelay);
  });

  test('tagged frames name their VLAN', () {
    const frame = Frame(
      src: MacAddress(2),
      dst: MacAddress.broadcast,
      vlan: 10,
      payload: ArpPacket(
        operation: ArpOperation.request,
        senderMac: MacAddress(2),
        senderIp: Ipv4Address(1),
        targetMac: MacAddress(0),
        targetIp: Ipv4Address(2),
      ),
    );
    expect(describeFrame(frame), endsWith('[VLAN 10]'));
    expect(frameKind(frame), FrameKind.arp);
  });
}
