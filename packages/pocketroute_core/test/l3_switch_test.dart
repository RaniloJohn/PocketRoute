// A campus core: an L3 switch routes between VLANs with SVIs and reaches the
// edge router over a routed port.
//
//   pcA (VLAN 10) --Fa0/1--+                                  Gi0/1
//                          ACC --Gi0/1 trunk-- Gi1/0/1 CORE      R1 --- pcR
//   pcB (VLAN 20) --Fa0/2--+          Gi1/1/1 routed --- Gi0/0      172.16.0.0/24
//                                       10.0.0.2/30   10.0.0.1/30

import 'package:pocketroute_core/pocketroute_core.dart';
import 'package:test/test.dart';

import 'support/terminals.dart';

void main() {
  late Network net;
  late MultilayerSwitch core;
  late L2Switch acc;
  late Router r1;
  late CliTerminal coreCli, accCli;
  late PcTerminal tA, tB;

  String pcRun(PcTerminal t, String command) {
    final out = StringBuffer(t.run(command));
    net.scheduler.runUntilIdle();
    return (out..write(t.drain())).toString();
  }

  String corePing(String target) {
    final out = StringBuffer(coreCli.run('ping $target'));
    net.scheduler.runUntilIdle();
    return (out..write(coreCli.drain())).toString();
  }

  setUp(() {
    net = Network();
    core = net.add(MultilayerSwitch('core', hostname: 'CORE'));
    acc = net.add(L2Switch('acc', hostname: 'ACC'));
    r1 = net.add(Router('r1', hostname: 'R1'));
    final pcA = net.add(Pc('pcA'));
    final pcB = net.add(Pc('pcB'));
    final pcR = net.add(Pc('pcR'));
    net
      ..connect(pcA.nic, acc.port('Fa0/1')!)
      ..connect(pcB.nic, acc.port('Fa0/2')!)
      ..connect(acc.port('Gi0/1')!, core.port('Gi1/0/1')!)
      ..connect(core.port('Gi1/1/1')!, r1.port('Gi0/0')!)
      ..connect(r1.port('Gi0/1')!, pcR.nic);

    accCli = CliTerminal(acc)
      ..runAll([
        'enable',
        'conf t',
        'vlan 10',
        'vlan 20',
        'int fa0/1',
        'switchport access vlan 10',
        'int fa0/2',
        'switchport access vlan 20',
        'int gi0/1',
        'switchport mode trunk',
        'end',
      ]);
    coreCli = CliTerminal(core);
    expect(
      coreCli.runAll([
        'enable',
        'conf t',
        'vlan 10',
        'name STAFF',
        'vlan 20',
        'name LAB',
        'interface vlan 10',
        'ip address 10.10.10.1 255.255.255.0',
        'no shutdown',
        'interface vlan 20',
        'ip address 10.10.20.1 255.255.255.0',
        'no shutdown',
        'interface gi1/0/1',
        'switchport mode trunk',
        'interface gi1/1/1',
        'no switchport',
        'ip address 10.0.0.2 255.255.255.252',
        'exit',
        'ip routing',
        'ip route 0.0.0.0 0.0.0.0 10.0.0.1',
        'end',
      ]),
      'Enter configuration commands, one per line.  End with CNTL/Z.\n',
    );
    CliTerminal(r1).runAll([
      'enable',
      'conf t',
      'int g0/0',
      'ip address 10.0.0.1 255.255.255.252',
      'no shutdown',
      'int g0/1',
      'ip address 172.16.0.1 255.255.255.0',
      'no shutdown',
      'exit',
      'ip route 10.10.0.0 255.255.0.0 10.0.0.2',
      'end',
    ]);
    tA = PcTerminal(pcA)..run('ipconfig 10.10.10.10 255.255.255.0 10.10.10.1');
    tB = PcTerminal(pcB)..run('ipconfig 10.10.20.10 255.255.255.0 10.10.20.1');
    PcTerminal(pcR).run('ipconfig 172.16.0.10 255.255.255.0 172.16.0.1');
    net.scheduler.runUntilIdle(); // spanning tree brings ports to forwarding
  });

  test('routes between VLANs through its SVIs', () {
    final out = pcRun(tA, 'ping 10.10.20.10');
    expect(out, contains('Received = 4'));
    expect(out, contains('TTL=127'));
  });

  test('does not route without ip routing', () {
    coreCli.runAll(['conf t', 'no ip routing', 'end']);
    expect(pcRun(tA, 'ping 10.10.20.10'), contains('Received = 0'));
    // Its own SVI addresses still answer.
    expect(pcRun(tA, 'ping 10.10.10.1'), contains('Received = 4'));
    expect(pcRun(tB, 'ping 10.10.20.1'), contains('Received = 4'));
  });

  test('reaches the edge router network over a routed port', () {
    final ping = pcRun(tA, 'ping 172.16.0.10');
    expect(ping, contains('Received = 4'));
    expect(ping, contains('TTL=126'));
    final trace = pcRun(tA, 'tracert 172.16.0.10');
    expect(trace, matches(RegExp(r'  1 .* 10\.10\.10\.1\n')));
    expect(trace, matches(RegExp(r'  2 .* 10\.0\.0\.1\n')));
    expect(trace, matches(RegExp(r'  3 .* 172\.16\.0\.10\n')));
  });

  test('the switch itself pings across its interfaces', () {
    expect(corePing('10.10.20.10'), contains('!!!!!'));
    expect(corePing('172.16.0.10'), contains('!!!!!'));
  });

  test('show ip route lists SVIs, the routed port and the default route', () {
    final out = coreCli.run('show ip route');
    expect(
      out,
      contains('Gateway of last resort is 10.0.0.1 to network 0.0.0.0'),
    );
    expect(out, contains('S*    0.0.0.0/0 [1/0] via 10.0.0.1\n'));
    expect(
      out,
      contains('C        10.10.10.0/24 is directly connected, Vlan10\n'),
    );
    expect(
      out,
      contains(
        'C        10.0.0.0/30 is directly connected, GigabitEthernet1/1/1\n',
      ),
    );
  });

  test('show ip interface brief shows SVIs and the routed port', () {
    final out = coreCli.run('show ip interface brief');
    expect(
      out,
      contains(
        'GigabitEthernet1/1/1   10.0.0.2        YES manual up'
        '                    up\n',
      ),
    );
    expect(
      out,
      contains(
        'Vlan10                 10.10.10.1      YES manual up'
        '                    up\n',
      ),
    );
    expect(
      out,
      contains(
        'Vlan1                  unassigned      YES unset  administratively '
        'down down\n',
      ),
    );
  });

  test('an SVI is up only while a forwarding port carries its VLAN', () {
    coreCli.runAll([
      'conf t',
      'interface vlan 30',
      'ip address 10.10.30.1 255.255.255.0',
      'no shutdown',
    ]);
    expect(core.sviFor(30).isUp, isFalse); // VLAN 30 does not exist yet
    coreCli.runAll(['vlan 30', 'exit']);
    expect(core.sviFor(30).isUp, isTrue); // the trunk carries every VLAN
    coreCli.runAll(['int gi1/0/1', 'switchport trunk allowed vlan remove 30']);
    expect(core.sviFor(30).isUp, isFalse);
  });

  test('routed ports refuse switchport settings until made switch ports', () {
    coreCli.runAll(['conf t', 'int gi1/1/1']);
    expect(coreCli.run('switchport mode trunk'), contains('routed port'));
    coreCli.run('switchport');
    expect(core.isRouted(core.port('Gi1/1/1')!), isFalse);
    expect(
      coreCli.run('ip address 10.9.9.1 255.255.255.0'),
      contains('no switchport'),
    );
  });

  test('overlapping addresses are refused across SVIs and routed ports', () {
    coreCli.runAll(['conf t', 'interface vlan 40']);
    expect(
      coreCli.run('ip address 10.10.10.5 255.255.255.0'),
      contains('overlaps with Vlan10'),
    );
  });

  test('no interface vlan removes an SVI', () {
    coreCli.runAll(['conf t', 'interface vlan 50', 'exit']);
    expect(core.svis.containsKey(50), isTrue);
    coreCli.run('no interface vlan 50');
    expect(core.svis.containsKey(50), isFalse);
    expect(coreCli.run('no interface vlan 1'), contains('cannot be removed'));
  });

  test('config replays to the same state', () {
    final copy = Network().add(MultilayerSwitch('copy', hostname: 'CORE'));
    expect(applyConfig(copy, core.renderConfig()), isEmpty);
    expect(copy.renderConfig(), core.renderConfig());
    final config = core.renderConfig();
    expect(config, contains('!\nip routing\n!\n'));
    expect(
      config,
      contains(
        'interface GigabitEthernet1/1/1\n'
        ' no switchport\n'
        ' ip address 10.0.0.2 255.255.255.252\n'
        '!\n',
      ),
    );
    expect(
      config,
      contains(
        'interface Vlan10\n'
        ' ip address 10.10.10.1 255.255.255.0\n'
        ' no shutdown\n'
        '!\n',
      ),
    );
    expect(config, contains('ip route 0.0.0.0 0.0.0.0 10.0.0.1\n'));
  });

  test('a layer 2 switch has no extra SVIs, routed ports or routing', () {
    accCli.runAll(['conf t']);
    expect(accCli.run('interface vlan 10'), contains('use an L3 switch'));
    accCli.run('int fa0/3');
    expect(accCli.run('no switchport'), contains('use an L3 switch'));
    accCli.run('exit');
    expect(accCli.run('ip routing'), contains('Invalid input'));
  });
}
