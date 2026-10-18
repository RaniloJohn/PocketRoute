import 'package:pocketroute_core/pocketroute_core.dart';
import 'package:test/test.dart';

import 'support/terminals.dart';

void main() {
  late Network net;
  late L2Switch sw;
  late SwitchTerminal t;

  setUp(() {
    net = Network();
    sw = net.add(L2Switch('sw', fastEthernetPorts: 2, gigabitPorts: 0));
    final pc = net.add(Pc('pc'));
    net.connect(pc.nic, sw.port('Fa0/1')!);
    net.scheduler.runUntilIdle(); // spanning tree brings Fa0/1 to forwarding
    t = SwitchTerminal(sw);
    t.runAll([
      'enable',
      'configure terminal',
      'hostname S1',
      'interface fa0/1',
      'description to PC1',
      'interface fa0/2',
      'shutdown',
      'interface vlan 1',
      'ip address 192.168.1.2 255.255.255.0',
      'no shutdown',
      'exit',
      'ip default-gateway 192.168.1.1',
      'end',
    ]);
  });

  test('show ip interface brief', () {
    expect(
      t.run('show ip interface brief'),
      'Interface              IP-Address      OK? Method Status                Protocol\n'
      'FastEthernet0/1        unassigned      YES unset  up                    up\n'
      'FastEthernet0/2        unassigned      YES unset  administratively down down\n'
      'Vlan1                  192.168.1.2     YES manual up                    up\n',
    );
  });

  const expectedConfig =
      '!\n'
      'hostname S1\n'
      '!\n'
      'interface FastEthernet0/1\n'
      ' description to PC1\n'
      '!\n'
      'interface FastEthernet0/2\n'
      ' shutdown\n'
      '!\n'
      'interface Vlan1\n'
      ' ip address 192.168.1.2 255.255.255.0\n'
      ' no shutdown\n'
      '!\n'
      'ip default-gateway 192.168.1.1\n'
      '!\n'
      'end\n';

  test('show running-config', () {
    expect(
      t.run('show running-config'),
      'Building configuration...\n'
      '\n'
      'Current configuration : ${expectedConfig.length} bytes\n'
      '$expectedConfig',
    );
  });

  test('a fresh switch shows Vlan1 shut down with no address', () {
    final fresh = Network().add(
      L2Switch('x', fastEthernetPorts: 1, gigabitPorts: 0),
    );
    expect(
      fresh.renderConfig(),
      '!\n'
      'hostname Switch\n'
      '!\n'
      'interface FastEthernet0/1\n'
      '!\n'
      'interface Vlan1\n'
      ' no ip address\n'
      ' shutdown\n'
      '!\n'
      'end\n',
    );
  });

  test('saved config replays through the CLI to the same state', () {
    final copy = Network().add(
      L2Switch('copy', fastEthernetPorts: 2, gigabitPorts: 0),
    );
    expect(applyConfig(copy, sw.renderConfig()), isEmpty);
    expect(copy.renderConfig(), sw.renderConfig());
    expect(copy.port('Fa0/2')!.adminUp, isFalse);
    expect(copy.sviAdminUp, isTrue);
  });

  test('write memory saves the startup config', () {
    expect(t.run('show startup-config'), 'startup-config is not present\n');
    expect(t.run('wr'), 'Building configuration...\n[OK]\n');
    expect(t.run('show startup-config'), expectedConfig);
    t.runAll(['conf t', 'hostname Changed', 'end']);
    expect(t.run('show startup-config'), expectedConfig);
  });

  test('clearing the MAC table forgets learned addresses', () {
    sw.macTable.learn(const MacAddress(0x020000000001), 1, sw.port('Fa0/1')!);
    expect(sw.macTable.entries, hasLength(1));
    t.run('clear mac address-table dynamic');
    expect(sw.macTable.entries, isEmpty);
  });

  test('MAC entries age out', () {
    sw.macTable.learn(const MacAddress(0x020000000001), 1, sw.port('Fa0/1')!);
    net.scheduler.advance(300001);
    expect(sw.macTable.entries, isEmpty);
  });
}
