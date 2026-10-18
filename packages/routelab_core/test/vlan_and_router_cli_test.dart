import 'package:routelab_core/routelab_core.dart';
import 'package:test/test.dart';

import 'support/terminals.dart';

void main() {
  group('VLAN sets', () {
    test('parse and format ranges', () {
      expect(VlanSet.tryParse('10,20,30-32,1')!.format(), '1,10,20,30-32');
      expect(VlanSet.tryParse('5-3'), isNull);
      expect(VlanSet.tryParse('0'), isNull);
      expect(VlanSet.tryParse('4095'), isNull);
      expect(VlanSet.all().format(), '1-4094');
      expect(VlanSet(const []).format(), 'none');
    });
  });

  group('switch VLAN commands', () {
    late L2Switch sw;
    late CliTerminal t;

    setUp(() {
      final net = Network();
      sw = net.add(L2Switch('sw', fastEthernetPorts: 6, gigabitPorts: 2));
      t = CliTerminal(sw)..runAll(['enable', 'conf t']);
    });

    test('show vlan brief groups access ports and wraps long lists', () {
      t.runAll([
        'vlan 10',
        'name SALES',
        'int fa0/5',
        'switchport access vlan 10',
        'int fa0/6',
        'switchport access vlan 10',
        'int gi0/2',
        'switchport mode trunk',
        'end',
      ]);
      expect(
        t.run('show vlan brief'),
        'VLAN Name                             Status    Ports\n'
        '---- -------------------------------- --------- '
        '-------------------------------\n'
        '1    default                          active    '
        'Fa0/1, Fa0/2, Fa0/3, Fa0/4,\n'
        '                                                Gi0/1\n'
        '10   SALES                            active    Fa0/5, Fa0/6\n',
      );
    });

    test('an unknown access VLAN is created on the spot', () {
      t.run('int fa0/1');
      expect(
        t.run('switchport access vlan 30'),
        '% VLAN 30 did not exist; '
        'created it\n',
      );
      expect(sw.vlans[30], 'VLAN0030');
    });

    test('VLAN 1 cannot be deleted; others can', () {
      expect(t.run('no vlan 1'), contains('cannot be deleted'));
      t.runAll(['vlan 40', 'exit']);
      expect(sw.vlans.containsKey(40), isTrue);
      t.run('no vlan 40');
      expect(sw.vlans.containsKey(40), isFalse);
    });

    test('vlan mode prompt and name', () {
      t.run('vlan 50');
      expect(t.session.prompt, 'Switch(config-vlan)#');
      t.run('name LAB');
      expect(sw.vlans[50], 'LAB');
      t.run('no name');
      expect(sw.vlans[50], 'VLAN0050');
    });

    test('allowed VLAN list edits', () {
      t.runAll([
        'int gi0/1',
        'switchport trunk allowed vlan 10,20',
        'switchport trunk allowed vlan add 30-32',
        'switchport trunk allowed vlan remove 20',
      ]);
      expect(sw.switchport(sw.port('Gi0/1')!).allowed.format(), '10,30-32');
      t.run('no switchport trunk allowed vlan');
      expect(sw.switchport(sw.port('Gi0/1')!).allowed.isAll, isTrue);
    });

    test('switchport commands are refused on interface Vlan1', () {
      t.run('interface vlan 1');
      expect(t.run('switchport mode trunk'), contains('VLAN interface'));
    });

    test('spanning tree priority must be a multiple of 4096', () {
      expect(
        t.run('spanning-tree vlan 1 priority 1000'),
        contains('multiple of 4096'),
      );
      t.run('spanning-tree vlan 1 priority 4096');
      expect(sw.stp.priority, 4096);
      expect(sw.renderConfig(), contains('spanning-tree vlan 1 priority 4096'));
      t.run('no spanning-tree vlan 1 priority');
      expect(sw.stp.priority, 32768);
    });
  });

  group('router CLI', () {
    late Router router;
    late CliTerminal t;

    setUp(() {
      router = Network().add(Router('r'));
      t = CliTerminal(router)..runAll(['enable', 'conf t']);
    });

    test('ports start shut down', () {
      expect(router.ports.every((p) => !p.adminUp), isTrue);
    });

    test('subinterface prompt, and an address needs encapsulation first', () {
      t.run('interface g0/0.10');
      expect(t.session.prompt, 'Router(config-subif)#');
      expect(
        t.run('ip address 192.168.10.1 255.255.255.0'),
        contains('Set encapsulation dot1Q'),
      );
      t.runAll([
        'encapsulation dot1q 10',
        'ip address 192.168.10.1 255.255.255.0',
      ]);
      expect(router.interface('Gi0/0.10')!.address.toString(), '192.168.10.1');
    });

    test('encapsulation is only for subinterfaces', () {
      t.run('interface g0/0');
      expect(t.run('encapsulation dot1q 10'), contains('Invalid input'));
    });

    test('two subinterfaces cannot share a VLAN', () {
      t.runAll(['int g0/0.10', 'encapsulation dot1q 10', 'int g0/0.11']);
      expect(t.run('encapsulation dot1q 10'), contains('already used by'));
    });

    test('overlapping subnets are refused', () {
      t.runAll(['int g0/0', 'ip address 10.1.0.1 255.255.0.0', 'int g0/1']);
      expect(
        t.run('ip address 10.1.5.1 255.255.255.0'),
        '% 10.1.5.0 overlaps with GigabitEthernet0/0\n',
      );
    });

    test('ip route checks its arguments', () {
      expect(
        t.run('ip route 10.1.1.1 255.255.255.0 10.0.0.2'),
        contains('not the network address'),
      );
      expect(
        t.run('ip route 10.1.1.0 255.0.255.0 10.0.0.2'),
        contains('not a valid subnet mask'),
      );
      expect(t.run('ip route 10.1.1.0 255.255.255.0 g0/3'), isEmpty);
      t.run('ip route 10.2.0.0 255.255.0.0 10.0.0.2');
      expect(router.staticRoutes, hasLength(2));
      t.run('no ip route 10.2.0.0 255.255.0.0');
      expect(router.staticRoutes, hasLength(1));
      expect(router.staticRoutes.single.exitInterface, 'GigabitEthernet0/3');
    });

    test('no interface removes a subinterface', () {
      t.runAll(['int g0/1.5', 'exit']);
      expect(router.interface('Gi0/1.5'), isNotNull);
      t.run('no interface g0/1.5');
      expect(router.interface('Gi0/1.5'), isNull);
      expect(t.run('no interface g0/1'), contains('Only subinterfaces'));
    });
  });
}
