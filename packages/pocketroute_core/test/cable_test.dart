import 'package:pocketroute_core/pocketroute_core.dart';
import 'package:test/test.dart';

import 'support/terminals.dart';

void main() {
  late Network net;

  setUp(() => net = Network());

  group('copper', () {
    test('automatic cabling picks straight-through or crossover', () {
      final sw1 = net.add(L2Switch('sw1'));
      final sw2 = net.add(L2Switch('sw2'));
      final r1 = net.add(Router('r1'));
      final r2 = net.add(Router('r2'));
      final pc = net.add(Pc('pc'));
      final pc2 = net.add(Pc('pc2'));
      expect(
        net.connect(pc.nic, sw1.port('Fa0/1')!).cable,
        CableType.copperStraight,
      );
      expect(
        net.connect(r1.port('Gi0/0')!, sw1.port('Fa0/2')!).cable,
        CableType.copperStraight,
      );
      expect(
        net.connect(sw1.port('Gi0/1')!, sw2.port('Gi0/1')!).cable,
        CableType.copperCross,
      );
      expect(
        net.connect(r1.port('Gi0/1')!, r2.port('Gi0/0')!).cable,
        CableType.copperCross,
      );
      expect(
        net.connect(pc2.nic, r2.port('Gi0/1')!).cable,
        CableType.copperCross,
      );
    });

    test('the wrong copper cable leaves the link down', () {
      final sw1 = net.add(L2Switch('sw1'));
      final sw2 = net.add(L2Switch('sw2'));
      final link = net.connect(
        sw1.port('Gi0/1')!,
        sw2.port('Gi0/1')!,
        cable: CableType.copperStraight,
      );
      expect(link.works, isFalse);
      expect(sw1.port('Gi0/1')!.isUp, isFalse);
      expect(
        CliTerminal(sw1).run('show ip interface brief'),
        contains('GigabitEthernet0/1     unassigned      YES unset  down'),
      );
    });
  });

  group('serial', () {
    late Router r1, r2;
    late CliTerminal r1Cli, r2Cli;

    setUp(() {
      r1 = net.add(Router('r1'));
      r2 = net.add(Router('r2'));
      net.connect(r1.port('S0/0/0')!, r2.port('S0/0/0')!);
      r1Cli = CliTerminal(r1)
        ..runAll([
          'en',
          'conf t',
          'int s0/0/0',
          'ip address 10.0.0.1 255.255.255.252',
          'no shutdown',
        ]);
      r2Cli = CliTerminal(r2)
        ..runAll([
          'en',
          'conf t',
          'int s0/0/0',
          'ip address 10.0.0.2 255.255.255.252',
          'no shutdown',
        ]);
    });

    String ping(String target) {
      final out = StringBuffer(r1Cli.run('end'))
        ..write(r1Cli.run('ping $target'));
      net.scheduler.runUntilIdle();
      return (out..write(r1Cli.drain())).toString();
    }

    test('stays down until the DCE end supplies a clock', () {
      expect(r1.port('S0/0/0')!.isUp, isFalse);
      expect(ping('10.0.0.2'), contains('Success rate is 0 percent'));
      r1Cli.runAll(['conf t', 'int s0/0/0', 'clock rate 64000']);
      expect(r1.port('S0/0/0')!.isUp, isTrue);
      expect(ping('10.0.0.2'), contains('!!!!!'));
      expect(r1.renderConfig(), contains(' clock rate 64000\n'));
    });

    test('the DTE end warns that the clock belongs on the DCE', () {
      expect(r2Cli.run('clock rate 64000'), contains('DTE'));
      expect(r2Cli.run('clock rate 1234'), contains('Unsupported clock rate'));
    });

    test('clock rate is refused on Ethernet', () {
      r1Cli.run('int g0/0');
      expect(r1Cli.run('clock rate 64000'), contains('serial interfaces only'));
    });
  });

  group('console', () {
    test('joins a host RS-232 port to a console port and carries nothing', () {
      final sw = net.add(L2Switch('sw'));
      final laptop = net.add(Pc('admin', kind: HostKind.laptop));
      final link = net.connect(laptop.rs232, sw.port('Console')!);
      expect(link.cable, CableType.console);
      expect(link.works, isFalse);
      expect(laptop.consoleTarget, same(sw));
    });

    test('a cable that does not fit is refused', () {
      final sw = net.add(L2Switch('sw'));
      final pc = net.add(Pc('pc'));
      expect(
        () => net.connect(pc.nic, sw.port('Console')!),
        throwsArgumentError,
      );
      expect(
        () => net.connect(pc.nic, sw.port('Fa0/1')!, cable: CableType.serial),
        throwsArgumentError,
      );
    });
  });
}
