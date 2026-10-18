import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:pocketroute_core/pocketroute_core.dart';
import 'package:test/test.dart';

import 'support/terminals.dart';

/// Router-on-a-stick, built through the CLI the way a student would.
Lab buildLab() {
  final lab = Lab(name: 'Inter-VLAN', notes: '# Try\nPing PC-B from PC-A.');
  final net = lab.network;
  final sw = net.add(L2Switch('s1', hostname: 'S1'));
  final r1 = net.add(Router('r1', hostname: 'R1'));
  final a = net.add(Pc('pa', hostname: 'PC-A'));
  final b = net.add(Pc('pb', hostname: 'PC-B', kind: HostKind.laptop));
  lab.devices.addAll([
    LabDevice(sw, 300, 200),
    LabDevice(r1, 300, 60),
    LabDevice(a, 160, 340),
    LabDevice(b, 440, 340),
  ]);
  net
    ..connect(a.nic, sw.port('Fa0/1')!)
    ..connect(b.nic, sw.port('Fa0/2')!)
    ..connect(sw.port('Gi0/1')!, r1.port('Gi0/0')!);
  CliTerminal(sw).runAll([
    'en',
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
    'write memory',
  ]);
  CliTerminal(r1).runAll([
    'en',
    'conf t',
    'int g0/0',
    'no shutdown',
    'int g0/0.10',
    'encapsulation dot1Q 10',
    'ip address 10.0.10.1 255.255.255.0',
    'int g0/0.20',
    'encapsulation dot1Q 20',
    'ip address 10.0.20.1 255.255.255.0',
    'end',
  ]);
  PcTerminal(a).run('ipconfig 10.0.10.10 255.255.255.0 10.0.10.1');
  PcTerminal(b).run('ipconfig 10.0.20.10 255.255.255.0 10.0.20.1');
  return lab;
}

void main() {
  test('a saved lab reopens with the same configs, cables and positions', () {
    final original = buildLab();
    final warnings = <String>[];
    final copy = LabFile.read(LabFile.write(original), warnings: warnings);

    expect(warnings, isEmpty);
    expect(copy.name, 'Inter-VLAN');
    expect(copy.notes, '# Try\nPing PC-B from PC-A.');
    expect(copy.devices.map((d) => (d.device.hostname, d.x, d.y)), [
      ('S1', 300, 200),
      ('R1', 300, 60),
      ('PC-A', 160, 340),
      ('PC-B', 440, 340),
    ]);
    expect(copy.devices.last.model, DeviceModel.laptop);
    expect(copy.network.links, hasLength(3));
    for (final id in ['s1', 'r1']) {
      expect(
        (copy.network[id]! as ConfigurableDevice).renderConfig(),
        (original.network[id]! as ConfigurableDevice).renderConfig(),
      );
    }
    final sw = copy.network['s1']! as L2Switch;
    expect(sw.startupConfig, isNotNull);
    expect((copy.network['pb']! as Pc).ip.gateway.toString(), '10.0.20.1');
  });

  test('a reopened lab works: inter-VLAN ping succeeds', () {
    final copy = LabFile.read(LabFile.write(buildLab()));
    copy.network.scheduler.runUntilIdle();
    final t = PcTerminal(copy.network['pa']! as Pc);
    final out = StringBuffer(t.run('ping 10.0.20.10'));
    copy.network.scheduler.runUntilIdle();
    out.write(t.drain());
    expect(out.toString(), contains('Received = 4'));
  });

  test('MAC addresses stay the same across save and load', () {
    final original = buildLab();
    final copy = LabFile.read(LabFile.write(original));
    expect(
      (copy.network['pa']! as Pc).nic.mac,
      (original.network['pa']! as Pc).nic.mac,
    );
  });

  test('topology.json is readable and versioned', () {
    final json = LabFile.encode(buildLab());
    expect(json['format'], 'pocketroute-lab');
    expect(json['version'], 1);
    final links = json['links']! as List;
    expect(links.first, {
      'a': ['pa', 'FastEthernet0'],
      'b': ['s1', 'FastEthernet0/1'],
      'cable': 'copperStraight',
    });
  });

  group('bad files', () {
    test('random bytes are refused', () {
      expect(
        () => LabFile.read(utf8.encode('hello')),
        throwsA(isA<LabFormatException>()),
      );
    });

    test('a newer version asks for an app update', () {
      final json = LabFile.encode(buildLab())..['version'] = 99;
      expect(
        () => LabFile.decode(json),
        throwsA(
          isA<LabFormatException>().having(
            (e) => e.message,
            'message',
            contains('newer PocketRoute'),
          ),
        ),
      );
    });

    test('unknown devices and broken cables become warnings', () {
      final json = LabFile.encode(buildLab());
      (json['devices']! as List).add({
        'id': 'x9',
        'model': 'firewall',
        'hostname': 'FW',
        'pos': [0, 0],
      });
      (json['links']! as List).add({
        'a': ['x9', 'Gi0/0'],
        'b': ['s1', 'Fa0/9'],
        'cable': 'copperStraight',
      });
      final warnings = <String>[];
      final lab = LabFile.decode(json, warnings: warnings);
      expect(lab.devices, hasLength(4));
      expect(warnings, [
        'Skipped x9: unknown device type firewall',
        'Skipped a cable to a missing port',
      ]);
    });

    test('a zip without topology.json is refused', () {
      final bytes = ZipEncoder().encode(
        Archive()..addFile(ArchiveFile.string('notes.md', 'hi')),
      );
      expect(() => LabFile.read(bytes), throwsA(isA<LabFormatException>()));
    });
  });
}
