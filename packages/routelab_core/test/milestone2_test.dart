// Milestone 2 gate: router-on-a-stick inter-VLAN routing configured entirely
// through the CLI, plus static routing across a second router.
//
//   pcA (VLAN 10) --Fa0/1--+
//   pcC (VLAN 10) --Fa0/3--+ S1 --Gi0/1 trunk-- Gi0/0 R1 --Gi0/1-- Gi0/0 R2 --Gi0/1-- pcR
//   pcB (VLAN 20) --Fa0/2--+               (.10 / .20 subifs)   10.0.0.0/30         172.16.0.0/24

import 'package:routelab_core/routelab_core.dart';
import 'package:test/test.dart';

import 'support/terminals.dart';

void main() {
  late Network net;
  late L2Switch s1;
  late Router r1, r2;
  late Pc pcA, pcB, pcC, pcR;
  late CliTerminal s1Cli, r1Cli, r2Cli;
  late PcTerminal tA, tB, tC, tR;

  String pingFrom(PcTerminal t, String args) {
    final out = StringBuffer(t.run('ping $args'));
    net.scheduler.runUntilIdle();
    return (out..write(t.drain())).toString();
  }

  String tracertFrom(PcTerminal t, String target) {
    final out = StringBuffer(t.run('tracert $target'));
    net.scheduler.runUntilIdle();
    return (out..write(t.drain())).toString();
  }

  String routerPing(CliTerminal t, String target) {
    final out = StringBuffer(t.run('ping $target'));
    net.scheduler.runUntilIdle();
    return (out..write(t.drain())).toString();
  }

  setUp(() {
    net = Network();
    s1 = net.add(L2Switch('s1'));
    r1 = net.add(Router('r1'));
    r2 = net.add(Router('r2'));
    pcA = net.add(Pc('pcA'));
    pcB = net.add(Pc('pcB'));
    pcC = net.add(Pc('pcC'));
    pcR = net.add(Pc('pcR'));
    net
      ..connect(pcA.nic, s1.port('Fa0/1')!)
      ..connect(pcB.nic, s1.port('Fa0/2')!)
      ..connect(pcC.nic, s1.port('Fa0/3')!)
      ..connect(s1.port('Gi0/1')!, r1.port('Gi0/0')!)
      ..connect(r1.port('Gi0/1')!, r2.port('Gi0/0')!)
      ..connect(r2.port('Gi0/1')!, pcR.nic);

    s1Cli = CliTerminal(s1);
    r1Cli = CliTerminal(r1);
    r2Cli = CliTerminal(r2);
    expect(
      s1Cli.runAll([
        'enable',
        'configure terminal',
        'vlan 10',
        'name SALES',
        'vlan 20',
        'name ENG',
        'interface fa0/1',
        'switchport mode access',
        'switchport access vlan 10',
        'interface fa0/3',
        'switchport access vlan 10',
        'interface fa0/2',
        'switchport access vlan 20',
        'interface gi0/1',
        'switchport mode trunk',
        'end',
      ]),
      'Enter configuration commands, one per line.  End with CNTL/Z.\n',
    );
    expect(
      r1Cli.runAll([
        'enable',
        'conf t',
        'interface g0/0',
        'no shutdown',
        'interface g0/0.10',
        'encapsulation dot1Q 10',
        'ip address 192.168.10.1 255.255.255.0',
        'interface g0/0.20',
        'encapsulation dot1Q 20',
        'ip address 192.168.20.1 255.255.255.0',
        'interface g0/1',
        'ip address 10.0.0.1 255.255.255.252',
        'no shutdown',
        'exit',
        'ip route 172.16.0.0 255.255.255.0 10.0.0.2',
        'end',
      ]),
      'Enter configuration commands, one per line.  End with CNTL/Z.\n',
    );
    r2Cli.runAll([
      'enable',
      'conf t',
      'interface g0/0',
      'ip address 10.0.0.2 255.255.255.252',
      'no shutdown',
      'interface g0/1',
      'ip address 172.16.0.1 255.255.255.0',
      'no shutdown',
      'exit',
      'ip route 192.168.0.0 255.255.0.0 10.0.0.1',
      'end',
    ]);

    tA = PcTerminal(pcA);
    tB = PcTerminal(pcB);
    tC = PcTerminal(pcC);
    tR = PcTerminal(pcR);
    tA.run('ipconfig 192.168.10.10 255.255.255.0 192.168.10.1');
    tC.run('ipconfig 192.168.10.11 255.255.255.0 192.168.10.1');
    tB.run('ipconfig 192.168.20.10 255.255.255.0 192.168.20.1');
    tR.run('ipconfig 172.16.0.10 255.255.255.0 172.16.0.1');
    net.scheduler.runUntilIdle(); // spanning tree: ports to forwarding
  });

  test('inter-VLAN ping goes through the router (TTL drops by one)', () {
    final out = pingFrom(tA, '192.168.20.10');
    expect(out, contains('Sent = 4, Received = 4, Lost = 0'));
    expect(out, contains('TTL=127'));
  });

  test('same-VLAN ping stays on the switch (TTL unchanged)', () {
    final out = pingFrom(tA, '192.168.10.11');
    expect(out, contains('Received = 4'));
    expect(out, contains('TTL=128'));
  });

  test('VLANs separate hosts even on the same subnet', () {
    // pcB moves onto VLAN 10's subnet but stays in VLAN 20.
    tB.run('ipconfig 192.168.10.20 255.255.255.0');
    expect(pingFrom(tA, '192.168.10.20'), contains('Received = 0'));
  });

  test('a native VLAN mismatch breaks VLAN 10, matching it repairs it', () {
    s1Cli.runAll([
      'conf t',
      'int gi0/1',
      'switchport trunk native vlan 10',
      'end',
    ]);
    // VLAN 10 now leaves the switch untagged; R1 only accepts it tagged.
    expect(pingFrom(tA, '192.168.20.10'), contains('Received = 0'));
    // VLAN 20 is still tagged and still reaches its gateway.
    expect(pingFrom(tB, '192.168.20.1'), contains('Received = 4'));

    r1Cli.runAll([
      'conf t',
      'int g0/0.10',
      'encapsulation dot1Q 10 native',
      'end',
    ]);
    expect(pingFrom(tA, '192.168.20.10'), contains('Received = 4'));
  });

  test('removing a VLAN from the trunk cuts it off', () {
    s1Cli.runAll([
      'conf t',
      'int gi0/1',
      'switchport trunk allowed vlan remove 20',
      'end',
    ]);
    expect(pingFrom(tA, '192.168.20.10'), contains('Received = 0'));
  });

  test('static routes reach a network two routers away', () {
    final out = pingFrom(tA, '172.16.0.10');
    expect(out, contains('Received = 4'));
    expect(out, contains('TTL=126'));
  });

  test('tracert lists each router hop', () {
    final out = tracertFrom(tA, '172.16.0.10');
    expect(out, contains('Tracing route to 172.16.0.10 over a maximum of 30'));
    expect(out, matches(RegExp(r'  1 .* 192\.168\.10\.1\n')));
    expect(out, matches(RegExp(r'  2 .* 10\.0\.0\.2\n')));
    expect(out, matches(RegExp(r'  3 .* 172\.16\.0\.10\n')));
    expect(out, contains('Trace complete.'));
  });

  test('a router answers for networks it has no route to', () {
    final out = pingFrom(tA, '10.99.0.1');
    expect(
      out,
      contains('Reply from 192.168.10.1: Destination host unreachable.'),
    );
  });

  test('a routing loop ends with TTL expired', () {
    r1Cli.runAll(['conf t', 'ip route 8.8.8.0 255.255.255.0 10.0.0.2', 'end']);
    r2Cli.runAll(['conf t', 'ip route 8.8.8.0 255.255.255.0 10.0.0.1', 'end']);
    expect(pingFrom(tA, '-n 1 8.8.8.8'), contains('TTL expired in transit.'));
  });

  test('the router pings hosts in each VLAN', () {
    final out = routerPing(r1Cli, '192.168.20.10');
    expect(out, contains('Sending 5, 100-byte ICMP Echos to 192.168.20.10'));
    expect(out, contains('Success rate is'));
    expect(routerPing(r1Cli, '192.168.20.10'), contains('!!!!!'));
    expect(routerPing(r1Cli, '172.16.0.10'), contains('!!!!!'));
    expect(routerPing(r1Cli, '10.99.0.1'), contains('.....'));
  });

  test('show ip route', () {
    expect(
      r1Cli.run('show ip route'),
      'Codes: L - local, C - connected, S - static, * - candidate default\n'
      '\n'
      'Gateway of last resort is not set\n'
      '\n'
      '      10.0.0.0/8 is variably subnetted, 2 subnets, 2 masks\n'
      'C        10.0.0.0/30 is directly connected, GigabitEthernet0/1\n'
      'L        10.0.0.1/32 is directly connected, GigabitEthernet0/1\n'
      '      172.16.0.0/24 is subnetted, 1 subnets\n'
      'S        172.16.0.0/24 [1/0] via 10.0.0.2\n'
      '      192.168.10.0/24 is variably subnetted, 2 subnets, 2 masks\n'
      'C        192.168.10.0/24 is directly connected, GigabitEthernet0/0.10\n'
      'L        192.168.10.1/32 is directly connected, GigabitEthernet0/0.10\n'
      '      192.168.20.0/24 is variably subnetted, 2 subnets, 2 masks\n'
      'C        192.168.20.0/24 is directly connected, GigabitEthernet0/0.20\n'
      'L        192.168.20.1/32 is directly connected, GigabitEthernet0/0.20\n',
    );
    expect(
      r2Cli.run('show ip route'),
      contains('S     192.168.0.0/16 [1/0] via 10.0.0.1\n'),
    );
  });

  test('a default route sets the gateway of last resort', () {
    r2Cli.runAll(['conf t', 'ip route 0.0.0.0 0.0.0.0 10.0.0.1', 'end']);
    final out = r2Cli.run('show ip route');
    expect(
      out,
      contains('Gateway of last resort is 10.0.0.1 to network 0.0.0.0'),
    );
    expect(out, contains('S*    0.0.0.0/0 [1/0] via 10.0.0.1\n'));
  });

  test('a static route leaves the table when its next hop is unreachable', () {
    expect(r1.lookup(Ipv4Address.parse('172.16.0.10')), isNotNull);
    r1Cli.runAll(['conf t', 'int g0/1', 'shutdown', 'end']);
    expect(r1.lookup(Ipv4Address.parse('172.16.0.10')), isNull);
    expect(r1Cli.run('show ip route'), isNot(contains('172.16.0.0')));
  });

  test('show ip interface brief lists subinterfaces', () {
    final out = r1Cli.run('show ip interface brief');
    expect(
      out,
      contains(
        'GigabitEthernet0/0.10  192.168.10.1    YES manual up'
        '                    up\n',
      ),
    );
    expect(
      out,
      contains(
        'GigabitEthernet0/2     unassigned      YES unset  administratively '
        'down down\n',
      ),
    );
  });

  test('show ip arp lists the router and its neighbours', () {
    pingFrom(tA, '192.168.10.1');
    final out = r1Cli.run('show ip arp');
    expect(
      out,
      startsWith(
        'Protocol  Address          Age (min)  Hardware Addr   Type   '
        'Interface\n',
      ),
    );
    expect(
      out,
      contains(
        'Internet  192.168.10.10            0  '
        '${pcA.nic.mac.toDotted()}  ARPA   GigabitEthernet0/0.10\n',
      ),
    );
    expect(
      out,
      contains(
        'Internet  192.168.10.1             -  '
        '${r1.port('Gi0/0')!.mac.toDotted()}  ARPA   GigabitEthernet0/0.10\n',
      ),
    );
  });

  test('router config replays to the same state', () {
    final copy = Network().add(Router('copy'));
    expect(applyConfig(copy, r1.renderConfig()), isEmpty);
    expect(copy.renderConfig(), r1.renderConfig());
    expect(r1.renderConfig(), contains(' encapsulation dot1Q 10\n'));
    expect(r1.renderConfig(), contains(' shutdown\n')); // Gi0/2, Gi0/3
    expect(copy.port('Gi0/2')!.adminUp, isFalse);
    expect(copy.port('Gi0/0')!.adminUp, isTrue);
  });

  test('switch config with VLANs and a trunk replays to the same state', () {
    s1Cli.runAll([
      'conf t',
      'int gi0/1',
      'switchport trunk native vlan 99',
      'switchport trunk allowed vlan 1,10,20,99',
      'int fa0/1',
      'spanning-tree portfast',
      'end',
    ]);
    final copy = Network().add(L2Switch('copy'));
    expect(applyConfig(copy, s1.renderConfig()), isEmpty);
    expect(copy.renderConfig(), s1.renderConfig());
    expect(
      s1.renderConfig(),
      contains(
        'interface GigabitEthernet0/1\n'
        ' switchport trunk native vlan 99\n'
        ' switchport trunk allowed vlan 1,10,20,99\n'
        ' switchport mode trunk\n'
        '!\n',
      ),
    );
  });
}
