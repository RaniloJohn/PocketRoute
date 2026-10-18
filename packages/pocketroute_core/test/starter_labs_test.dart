// The starter labs shipped in app/assets/labs behave as their notes say.
// Rebuild them with: dart run tool/build_starter_labs.dart

import 'dart:io';

import 'package:pocketroute_core/pocketroute_core.dart';
import 'package:test/test.dart';

import 'support/terminals.dart';

Lab open(String name) {
  final warnings = <String>[];
  final lab = LabFile.read(
    File('../../app/assets/labs/$name.prlab').readAsBytesSync(),
    warnings: warnings,
  );
  expect(warnings, isEmpty);
  lab.network.scheduler.runUntilIdle();
  return lab;
}

Device named(Lab lab, String hostname) =>
    lab.devices.firstWhere((d) => d.device.hostname == hostname).device;

String ping(Lab lab, String from, String target) {
  final t = PcTerminal(named(lab, from) as Pc);
  final out = StringBuffer(t.run('ping $target'));
  lab.network.scheduler.runUntilIdle();
  return (out..write(t.drain())).toString();
}

void main() {
  test('every starter lab has a name and notes', () {
    final files = Directory('../../app/assets/labs')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.prlab'));
    expect(files, hasLength(5));
    for (final file in files) {
      final lab = LabFile.read(file.readAsBytesSync());
      expect(lab.name, isNot('Untitled lab'));
      expect(lab.notes, startsWith('# '));
    }
  });

  test('first LAN starts unconfigured', () {
    final lab = open('01-first-lan');
    expect((named(lab, 'PC1') as Pc).ip.address, isNull);
  });

  test('router on a stick routes between VLANs', () {
    expect(
      ping(open('02-router-on-a-stick'), 'PC-A', '10.0.20.10'),
      contains('TTL=127'),
    );
  });

  test('campus core reaches the server behind the edge router', () {
    final lab = open('03-campus-core');
    expect(ping(lab, 'PC1', '10.10.20.11'), contains('Received = 4'));
    expect(ping(lab, 'PC1', '172.16.0.10'), contains('TTL=126'));
  });

  test('spanning tree lab blocks exactly one port', () {
    final lab = open('04-spanning-tree');
    final blocked = [
      for (final d in lab.devices)
        if (d.device case final L2Switch sw)
          for (final port in sw.ports)
            if (sw.stp.role(port) == StpRole.alternate) port,
    ];
    expect(blocked, hasLength(1));
    expect(ping(lab, 'PC2', '10.0.0.3'), contains('Received = 4'));
  });

  test('serial WAN is broken until the DCE gets a clock rate', () {
    final lab = open('05-serial-wan');
    // The serial route is not installed while the line is down, so BR1
    // answers "unreachable" (which Windows-style ping counts as received).
    expect(
      ping(lab, 'PC1', '192.168.2.10'),
      contains('Reply from 192.168.1.1: Destination host unreachable.'),
    );
    CliTerminal(named(lab, 'BR1') as Router)
        .runAll(['en', 'conf t', 'int s0/0/0', 'clock rate 64000', 'end']);
    expect(ping(lab, 'PC1', '192.168.2.10'), contains('TTL=126'));
  });
}
