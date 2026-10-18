// Spanning tree on a triangle of switches:
//
//        S1 (priority 4096: root)
//    Gi0/1 /      \ Gi0/2
//   Gi0/1 /        \ Gi0/1
//       S2 -------- S3
//          Gi0/2  Gi0/2
//   pc2 on S2 Fa0/1, pc3 on S3 Fa0/1

import 'package:routelab_core/routelab_core.dart';
import 'package:test/test.dart';

import 'support/terminals.dart';

void main() {
  late Network net;
  late L2Switch s1, s2, s3;
  late Pc pc2, pc3;
  late PcTerminal t2;

  List<(L2Switch, Port)> alternatePorts() => [
    for (final sw in [s1, s2, s3])
      for (final port in sw.ports)
        if (sw.stp.role(port) == StpRole.alternate) (sw, port),
  ];

  String ping(String target) {
    final out = StringBuffer(t2.run('ping $target'));
    net.scheduler.runUntilIdle();
    return (out..write(t2.drain())).toString();
  }

  setUp(() {
    net = Network();
    s1 = net.add(L2Switch('s1'));
    s2 = net.add(L2Switch('s2'));
    s3 = net.add(L2Switch('s3'));
    CliTerminal(s1)
        .runAll(['en', 'conf t', 'spanning-tree vlan 1 priority 4096']);
    pc2 = net.add(Pc('pc2'));
    pc3 = net.add(Pc('pc3'));
    net
      ..connect(s1.port('Gi0/1')!, s2.port('Gi0/1')!)
      ..connect(s1.port('Gi0/2')!, s3.port('Gi0/1')!)
      ..connect(s2.port('Gi0/2')!, s3.port('Gi0/2')!)
      ..connect(pc2.nic, s2.port('Fa0/1')!)
      ..connect(pc3.nic, s3.port('Fa0/1')!);
    t2 = PcTerminal(pc2)..run('ipconfig 10.0.0.2 255.255.255.0');
    PcTerminal(pc3).run('ipconfig 10.0.0.3 255.255.255.0');
    net.scheduler.runUntilIdle();
  });

  test('the lowest bridge ID becomes root', () {
    expect(s1.stp.isRoot, isTrue);
    expect(s2.stp.isRoot, isFalse);
    expect(s2.stp.rootId, s1.stp.bridgeId);
    expect(s2.stp.rootPort, s2.port('Gi0/1'));
    expect(s3.stp.rootPort, s3.port('Gi0/1'));
    expect(s2.stp.rootCost, 4);
  });

  test('exactly one port in the loop is blocked', () {
    final blocked = alternatePorts();
    expect(blocked, hasLength(1));
    // On the S2-S3 link the switch with the higher bridge ID blocks.
    final loser = s2.stp.bridgeId.compareTo(s3.stp.bridgeId) > 0 ? s2 : s3;
    expect(blocked.single.$1, same(loser));
    expect(blocked.single.$2.name, 'GigabitEthernet0/2');
    expect(loser.stp.state(blocked.single.$2), StpState.blocking);
  });

  test('hosts communicate across the loop without a broadcast storm', () {
    // A storm would keep the scheduler busy and runUntilIdle would throw.
    expect(ping('10.0.0.3'), contains('Received = 4'));
  });

  test('the blocked port takes over when a root link fails', () {
    final (loser, blockedPort) = alternatePorts().single;
    final winner = identical(loser, s2) ? s3 : s2;
    // Cut the winner's link to the root; its only path is now via the loser.
    CliTerminal(winner)
        .runAll(['en', 'conf t', 'int gi0/1', 'shutdown', 'end']);
    net.scheduler
      ..advance(SpanningTree.maxAge + 3 * SpanningTree.forwardDelay)
      ..runUntilIdle();
    expect(alternatePorts(), isEmpty);
    expect(loser.stp.state(blockedPort), StpState.forwarding);
    expect(ping('10.0.0.3'), contains('Received = 4'));
  });

  test('ports listen and learn before forwarding; portfast skips that', () {
    final sw = net.add(L2Switch('edge'));
    final a = net.add(Pc('a'));
    final b = net.add(Pc('b'));
    CliTerminal(sw)
        .runAll(['en', 'conf t', 'int fa0/2', 'spanning-tree portfast']);
    net
      ..connect(a.nic, sw.port('Fa0/1')!)
      ..connect(b.nic, sw.port('Fa0/2')!);
    expect(sw.stp.state(sw.port('Fa0/1')!), StpState.listening);
    expect(sw.stp.state(sw.port('Fa0/2')!), StpState.forwarding);
    net.scheduler.advance(SpanningTree.forwardDelay);
    expect(sw.stp.state(sw.port('Fa0/1')!), StpState.learning);
    net.scheduler.advance(SpanningTree.forwardDelay);
    expect(sw.stp.state(sw.port('Fa0/1')!), StpState.forwarding);
  });

  test('show spanning-tree on the root and a non-root switch', () {
    final root = CliTerminal(s1).run('show spanning-tree');
    expect(root, contains('             This bridge is the root\n'));
    expect(root, contains('Priority    4097  (priority 4096 sys-id-ext 1)'));
    expect(
      root,
      contains('Gi0/1               Desg FWD 4         128.25   P2p\n'),
    );

    final other = CliTerminal(s2).run('show spanning-tree');
    expect(other, contains('  Root ID    Priority    4097\n'));
    expect(other, contains('             Cost        4\n'));
    expect(
      other,
      contains('             Port        25 (GigabitEthernet0/1)\n'),
    );
    expect(
      other,
      contains('Gi0/1               Root FWD 4         128.25   P2p\n'),
    );
    expect(
      other,
      contains('Fa0/1               Desg FWD 19        128.1    P2p\n'),
    );
  });
}
