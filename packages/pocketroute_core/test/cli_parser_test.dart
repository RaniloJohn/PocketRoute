import 'package:pocketroute_core/pocketroute_core.dart';
import 'package:test/test.dart';

import 'support/terminals.dart';

void main() {
  late L2Switch sw;
  late SwitchTerminal t;

  setUp(() {
    final net = Network();
    sw = net.add(L2Switch('sw'));
    t = SwitchTerminal(sw);
  });

  test('prompts follow the mode', () {
    expect(t.session.prompt, 'Switch>');
    t.run('enable');
    expect(t.session.prompt, 'Switch#');
    t.run('configure terminal');
    expect(t.session.prompt, 'Switch(config)#');
    t.run('interface FastEthernet0/1');
    expect(t.session.prompt, 'Switch(config-if)#');
    t.run('exit');
    expect(t.session.prompt, 'Switch(config)#');
    t.run('interface fa0/1');
    t.session.ctrlZ();
    expect(t.session.prompt, 'Switch#');
    t.run('disable');
    expect(t.session.prompt, 'Switch>');
  });

  test('unique prefixes abbreviate every word', () {
    t.runAll(['en', 'conf t', 'host S1', 'int fa0/5', 'shut']);
    expect(sw.hostname, 'S1');
    expect(sw.port('Fa0/5')!.adminUp, isFalse);
    t.runAll(['no shut', 'end']);
    expect(sw.port('Fa0/5')!.adminUp, isTrue);
    expect(t.run('sh ip int br'), contains('FastEthernet0/5'));
  });

  test('interface type and number may be split by a space', () {
    t.runAll(['en', 'conf t', 'interface fastethernet 0/3', 'desc uplink']);
    expect(sw.port('Fa0/3')!.description, 'uplink');
  });

  test('a prefix shared by several keywords is ambiguous', () {
    t.run('enable');
    expect(t.run('c'), '% Ambiguous command:  "c"\n');
  });

  test('the caret marks the first bad word', () {
    t.runAll(['enable', 'configure terminal']);
    expect(
      t.run('hostnme R1'),
      '${' ' * 'Switch(config)#'.length}^\n'
      "% Invalid input detected at '^' marker.\n",
    );
    t.run('interface fa0/1');
    expect(
      t.run('ip adress 10.0.0.1 255.0.0.0'),
      '${' ' * ('Switch(config-if)#'.length + 3)}^\n'
      "% Invalid input detected at '^' marker.\n",
    );
  });

  test('a global command in interface mode runs and leaves interface mode', () {
    t.runAll(['enable', 'conf t', 'interface fa0/1']);
    expect(t.run('hostname Edge'), isEmpty);
    expect(sw.hostname, 'Edge');
    expect(t.session.mode, CliMode.globalConfig);
  });

  test('a command missing words is incomplete', () {
    t.run('enable');
    expect(t.run('configure'), '% Incomplete command.\n');
    expect(t.run('show ip'), '% Incomplete command.\n');
  });

  test('? lists what can come next, with <cr> when the command can end', () {
    t.run('enable');
    expect(
      t.run('write ?'),
      '  memory  Save it for the next start\n'
      '  <cr>\n',
    );
    final show = t.run('show ?').split('\n');
    expect(show.map((l) => l.trim().split(' ').first), [
      'interfaces',
      'ip',
      'mac',
      'running-config',
      'spanning-tree',
      'startup-config',
      'vlan',
      '',
    ]);
  });

  test('word? lists the keywords starting with it', () {
    t.run('enable');
    expect(t.run('co?'), 'configure  copy\n');
    expect(t.run('zz?'), '% Unrecognized command\n');
  });

  test('tab completes a unique prefix', () {
    t.run('enable');
    expect(t.session.complete('conf'), 'configure ');
    expect(t.session.complete('c'), isNull);
    expect(t.session.complete('show ip int'), 'show ip interface ');
    t.run('configure terminal');
    expect(t.session.complete('int fa'), 'int FastEthernet');
  });

  test('no forms undo settings', () {
    t.runAll([
      'enable',
      'conf t',
      'hostname Core',
      'ip default-gateway 10.0.0.1',
    ]);
    expect(sw.svi.gateway, Ipv4Address.parse('10.0.0.1'));
    t.runAll(['no ip default-gateway', 'no hostname']);
    expect(sw.svi.gateway, isNull);
    expect(sw.hostname, 'Switch');
    expect(t.run('no'), '% Incomplete command.\n');
  });

  test('bad values are rejected with a message', () {
    t.runAll(['enable', 'conf t']);
    expect(t.run('hostname 1abc'), startsWith('% Hostnames start'));
    expect(t.run('interface fa0/30'), contains('does not exist'));
    expect(t.run('interface vlan 10'), contains('Only interface Vlan1'));
    t.run('interface fa0/1');
    expect(t.run('ip address 10.0.0.1 255.0.0.0'), contains('layer 2'));
    t.run('interface vlan 1');
    expect(t.run('ip address 10.0.0.1 255.0.255.0'), contains('not a valid'));
    expect(t.run('ip address 10.0.0.0 255.0.0.0'), contains('not a usable'));
    expect(sw.svi.address, isNull);
  });

  test('history keeps every non-empty line', () {
    t.runAll(['enable', '', 'show ip int brief']);
    expect(t.session.history, ['enable', 'show ip int brief']);
  });
}
