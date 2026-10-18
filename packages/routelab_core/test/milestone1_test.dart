// Milestone 1 gate: two PCs on one switch ping each other using IP addresses
// set through the command line.

import 'package:routelab_core/routelab_core.dart';
import 'package:test/test.dart';

import 'support/terminals.dart';

/// A PC that records every frame its port delivers.
class RecordingPc extends Pc {
  RecordingPc(super.id);

  final frames = <Frame>[];

  @override
  void receive(Port port, Frame frame) {
    frames.add(frame);
    super.receive(port, frame);
  }
}

void main() {
  late Network net;
  late L2Switch sw;
  late Pc pc1, pc2;
  late RecordingPc pc3;
  late PcTerminal t1, t2;
  late SwitchTerminal console;

  setUp(() {
    net = Network();
    sw = net.add(L2Switch('sw1'));
    pc1 = net.add(Pc('pc1'));
    pc2 = net.add(Pc('pc2'));
    pc3 = net.add(RecordingPc('pc3'));
    net
      ..connect(pc1.nic, sw.port('Fa0/1')!)
      ..connect(pc2.nic, sw.port('Fa0/2')!)
      ..connect(pc3.nic, sw.port('Fa0/3')!);
    net.scheduler
        .runUntilIdle(); // spanning tree brings the ports to forwarding
    t1 = PcTerminal(pc1);
    t2 = PcTerminal(pc2);
    console = SwitchTerminal(sw);
    expect(t1.run('ipconfig 192.168.1.10 255.255.255.0'), isEmpty);
    expect(t2.run('ipconfig 192.168.1.11 255.255.255.0'), isEmpty);
  });

  String pingFrom(PcTerminal t, String target) {
    final out = StringBuffer(t.run('ping $target'));
    expect(t.shell.busy, isTrue);
    net.scheduler.runUntilIdle();
    out.write(t.drain());
    expect(t.shell.busy, isFalse);
    return out.toString();
  }

  test('PC to PC ping succeeds', () {
    final out = pingFrom(t1, '192.168.1.11');
    expect(out, contains('Pinging 192.168.1.11 with 32 bytes of data:'));
    expect(
      RegExp(r'Reply from 192\.168\.1\.11: bytes=32 time=\d+ms TTL=128')
          .allMatches(out),
      hasLength(4),
    );
    expect(out, contains('Sent = 4, Received = 4, Lost = 0 (0% loss)'));
  });

  test('the switch learns both PCs, and the bystander sees only the ARP flood', () {
    pingFrom(t1, '192.168.1.11');
    final table = console.run('show mac address-table');
    expect(table, contains('${pc1.nic.mac.toDotted()}    DYNAMIC     Fa0/1'));
    expect(table, contains('${pc2.nic.mac.toDotted()}    DYNAMIC     Fa0/2'));
    expect(table, contains('Total Mac Addresses for this criterion: 2'));

    // pc3 got the broadcast ARP request; replies and ICMP went only to pc1/pc2.
    // (It also hears the switch's spanning tree BPDUs, as real hosts do.)
    final data = pc3.frames.where((f) => f.payload is! Bpdu).toList();
    expect(data, hasLength(1));
    expect(data.single.payload, isA<ArpPacket>());
    expect(data.single.dst.isBroadcast, isTrue);
  });

  test('both PCs fill their ARP caches', () {
    pingFrom(t1, '192.168.1.11');
    expect(t1.run('arp -a'), contains(pc2.nic.mac.toHyphenated()));
    expect(t2.run('arp -a'), contains(pc1.nic.mac.toHyphenated()));
  });

  test('switch management address answers and pings out after CLI config', () {
    console.runAll([
      'enable',
      'configure terminal',
      'interface vlan 1',
      'ip address 192.168.1.2 255.255.255.0',
      'no shutdown',
      'end',
    ]);
    expect(pingFrom(t1, '192.168.1.2'), contains('Received = 4'));
    expect(pingFrom(t1, '192.168.1.2'), contains('TTL=255'));

    final out = StringBuffer(console.run('ping 192.168.1.11'));
    net.scheduler.runUntilIdle();
    out.write(console.drain());
    expect(out.toString(), contains('!!!!!'));
    expect(out.toString(), contains('Success rate is 100 percent (5/5)'));
  });

  test('ping fails when the far port is shut down', () {
    console.runAll(['en', 'conf t', 'int fa0/2', 'shutdown', 'end']);
    final out = pingFrom(t1, '192.168.1.11');
    expect('Request timed out.'.allMatches(out), hasLength(4));
    expect(out, contains('Received = 0, Lost = 4 (100% loss)'));
  });

  test('ping fails when the cable is pulled', () {
    net.disconnect(pc2.nic.link!);
    expect(pingFrom(t1, '192.168.1.11'), contains('Received = 0'));
  });

  test('a different subnet without a gateway is unreachable', () {
    t2.run('ipconfig 10.0.0.11 255.255.255.0');
    final out = pingFrom(t1, '10.0.0.11');
    expect(out, contains('Transmit failed: no route to 10.0.0.11.'));
    expect(out, contains('Received = 0'));
  });

  test('a duplicate subnet mask mismatch still fails cleanly', () {
    t2.run('ipconfig 192.168.2.11 255.255.255.0');
    expect(pingFrom(t1, '192.168.2.11'), contains('Received = 0'));
  });

  test('ping -n sets the count', () {
    expect(
      pingFrom(t1, '-n 2 192.168.1.11'),
      contains('Sent = 2, Received = 2'),
    );
  });
}
