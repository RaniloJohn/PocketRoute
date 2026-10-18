// Builds the starter labs shipped with the app, through the same CLI a
// student uses, and writes them to app/assets/labs/.
//
//   dart run tool/build_starter_labs.dart
//
// Run it again after changing a lab here or the lab file format.

import 'dart:io';

import 'package:pocketroute_core/pocketroute_core.dart';

void main() {
  final out = Directory('../../app/assets/labs')..createSync(recursive: true);
  final labs = {
    '01-first-lan': firstLan(),
    '02-router-on-a-stick': routerOnAStick(),
    '03-campus-core': campusCore(),
    '04-spanning-tree': spanningTree(),
    '05-serial-wan': serialWan(),
  };
  for (final MapEntry(key: file, value: lab) in labs.entries) {
    lab.network.scheduler.runUntilIdle();
    // Check it reopens cleanly before shipping it.
    final bytes = LabFile.write(lab);
    final warnings = <String>[];
    LabFile.read(bytes, warnings: warnings);
    if (warnings.isNotEmpty) {
      stderr.writeln('$file: $warnings');
      exitCode = 1;
      return;
    }
    File('${out.path}/$file.${LabFile.extension}').writeAsBytesSync(bytes);
    stdout.writeln('wrote $file (${lab.devices.length} devices)');
  }
}

/// Places [device] in [lab] at (x, y) and returns it.
T place<T extends Device>(Lab lab, T device, double x, double y) {
  lab.network.add(device);
  lab.devices.add(LabDevice(device, x, y));
  return device;
}

/// Types [lines] into [device]'s console from privileged configuration.
void configure(ConfigurableDevice device, List<String> lines) {
  final errors = StringBuffer();
  final cli = device.openCli(errors.write)
    ..execute('enable')
    ..execute('configure terminal');
  for (final line in lines) {
    cli.execute(line);
  }
  cli
    ..execute('end')
    ..execute('write memory');
  final problems = errors
      .toString()
      .split('\n')
      .where((l) => l.startsWith('%') && !l.startsWith('% Portfast'));
  if (problems.isNotEmpty) {
    throw StateError('${device.hostname}: ${problems.join('; ')}');
  }
}

void host(Pc pc, String address, String mask, [String? gateway]) {
  pc.ip.configure(Ipv4Address.parse(address), Ipv4Address.parse(mask));
  pc.ip.gateway = gateway == null ? null : Ipv4Address.parse(gateway);
}

Lab firstLan() {
  final lab = Lab(
    name: 'Your first LAN',
    notes: '''
# Your first LAN

Two PCs on one switch. Nothing is configured yet.

1. Double-tap **PC1**, open **IP settings** and give it `192.168.1.10`, mask
   `255.255.255.0`. Do the same for **PC2** with `192.168.1.11`.
2. In PC1's **Command prompt**, type `ping 192.168.1.11`.
3. Switch to **Simulation**, ping again, and press **Step** to watch the ARP
   request flood out of the switch, the reply come back, then the pings.
4. Open **SW1** and type `enable`, then `show mac address-table`. Which ports
   did the switch learn each PC on?
''',
  );
  final sw = place(lab, L2Switch('d1', hostname: 'SW1'), 500, 220);
  final pc1 = place(lab, Pc('d2', hostname: 'PC1'), 320, 420);
  final pc2 = place(lab, Pc('d3', hostname: 'PC2'), 680, 420);
  lab.network
    ..connect(pc1.nic, sw.port('Fa0/1')!)
    ..connect(pc2.nic, sw.port('Fa0/2')!);
  return lab;
}

Lab routerOnAStick() {
  final lab = Lab(
    name: 'Router on a stick',
    notes: '''
# Router on a stick

One router routes between two VLANs over a single 802.1Q trunk. Everything
works: start by pinging from **PC-A** (VLAN 10) to **PC-B** (`10.0.20.10`,
VLAN 20). The reply's TTL is 127: one router hop.

Explore:
- On **R1**: `show ip interface brief`, `show ip route`, `show running-config`.
- On **S1**: `show vlan brief`, `show interfaces trunk`.

Break it, then fix it:
- On S1, `interface gi0/1` then `switchport trunk native vlan 10`. Why does
  VLAN 10 stop working while VLAN 20 still works?
- Remove VLAN 20 from the trunk with
  `switchport trunk allowed vlan remove 20`.
''',
  );
  final r1 = place(lab, Router('d1', hostname: 'R1'), 500, 120);
  final s1 = place(lab, L2Switch('d2', hostname: 'S1'), 500, 300);
  final a = place(lab, Pc('d3', hostname: 'PC-A'), 340, 480);
  final b = place(lab, Pc('d4', hostname: 'PC-B'), 660, 480);
  lab.network
    ..connect(r1.port('Gi0/0')!, s1.port('Gi0/1')!)
    ..connect(a.nic, s1.port('Fa0/1')!)
    ..connect(b.nic, s1.port('Fa0/2')!);
  configure(s1, [
    'vlan 10',
    'name STAFF',
    'vlan 20',
    'name LAB',
    'interface fa0/1',
    'switchport access vlan 10',
    'interface fa0/2',
    'switchport access vlan 20',
    'interface gi0/1',
    'switchport mode trunk',
  ]);
  configure(r1, [
    'interface g0/0',
    'no shutdown',
    'interface g0/0.10',
    'encapsulation dot1Q 10',
    'ip address 10.0.10.1 255.255.255.0',
    'interface g0/0.20',
    'encapsulation dot1Q 20',
    'ip address 10.0.20.1 255.255.255.0',
  ]);
  host(a, '10.0.10.10', '255.255.255.0', '10.0.10.1');
  host(b, '10.0.20.10', '255.255.255.0', '10.0.20.1');
  return lab;
}

Lab campusCore() {
  final lab = Lab(
    name: 'Campus core',
    notes: '''
# Campus core

A layer 3 core switch routes between the VLANs with SVIs and reaches the
edge router over a routed port. Two access switches trunk up to the core.

- From **PC1** ping **PC3** (`10.10.20.11`): routed by **CORE**.
- From **PC1** ping the server behind the edge router (`172.16.0.10`), then
  run `tracert 172.16.0.10` to see both hops.
- On **CORE**: `show ip route`, `show ip interface brief`. Find the
  connected routes for each SVI and the default route.

Try: `no ip routing` on CORE. Which pings still work, and why?
''',
  );
  final edge = place(lab, Router('d1', hostname: 'EDGE'), 820, 120);
  final core = place(lab, MultilayerSwitch('d2', hostname: 'CORE'), 500, 120);
  final acc1 = place(lab, L2Switch('d3', hostname: 'ACC1'), 300, 320);
  final acc2 = place(lab, L2Switch('d4', hostname: 'ACC2'), 700, 320);
  final pc1 = place(lab, Pc('d5', hostname: 'PC1'), 200, 500);
  final pc2 = place(
    lab,
    Pc('d6', hostname: 'PC2', kind: HostKind.laptop),
    400,
    500,
  );
  final pc3 = place(lab, Pc('d7', hostname: 'PC3'), 700, 500);
  final srv = place(
    lab,
    Pc('d8', hostname: 'SRV1', kind: HostKind.server),
    1060,
    120,
  );
  lab.network
    ..connect(core.port('Gi1/1/1')!, edge.port('Gi0/0')!)
    ..connect(edge.port('Gi0/1')!, srv.nic)
    ..connect(core.port('Gi1/0/1')!, acc1.port('Gi0/1')!)
    ..connect(core.port('Gi1/0/2')!, acc2.port('Gi0/1')!)
    ..connect(pc1.nic, acc1.port('Fa0/1')!)
    ..connect(pc2.nic, acc1.port('Fa0/2')!)
    ..connect(pc3.nic, acc2.port('Fa0/1')!);
  for (final acc in [acc1, acc2]) {
    configure(acc, [
      'vlan 10',
      'name STAFF',
      'vlan 20',
      'name LAB',
      'interface gi0/1',
      'switchport mode trunk',
    ]);
  }
  configure(acc1, [
    'interface fa0/1',
    'switchport access vlan 10',
    'interface fa0/2',
    'switchport access vlan 20',
  ]);
  configure(acc2, ['interface fa0/1', 'switchport access vlan 20']);
  configure(core, [
    'vlan 10',
    'name STAFF',
    'vlan 20',
    'name LAB',
    'spanning-tree vlan 1 priority 4096',
    'interface gi1/0/1',
    'switchport mode trunk',
    'interface gi1/0/2',
    'switchport mode trunk',
    'interface vlan 10',
    'ip address 10.10.10.1 255.255.255.0',
    'no shutdown',
    'interface vlan 20',
    'ip address 10.10.20.1 255.255.255.0',
    'no shutdown',
    'interface gi1/1/1',
    'no switchport',
    'ip address 10.0.0.2 255.255.255.252',
    'exit',
    'ip routing',
    'ip route 0.0.0.0 0.0.0.0 10.0.0.1',
  ]);
  configure(edge, [
    'interface g0/0',
    'ip address 10.0.0.1 255.255.255.252',
    'no shutdown',
    'interface g0/1',
    'ip address 172.16.0.1 255.255.255.0',
    'no shutdown',
    'exit',
    'ip route 10.10.0.0 255.255.0.0 10.0.0.2',
  ]);
  host(pc1, '10.10.10.10', '255.255.255.0', '10.10.10.1');
  host(pc2, '10.10.20.10', '255.255.255.0', '10.10.20.1');
  host(pc3, '10.10.20.11', '255.255.255.0', '10.10.20.1');
  host(srv, '172.16.0.10', '255.255.255.0', '172.16.0.1');
  return lab;
}

Lab spanningTree() {
  final lab = Lab(
    name: 'Spanning tree loop',
    notes: '''
# Spanning tree loop

Three switches cabled in a triangle: a loop. Spanning tree blocks one port so
frames cannot circle forever. **S1** has the lowest priority, so it is the
root bridge.

1. Open each switch and run `show spanning-tree`. Which port is **Altn BLK**?
   Its link light on the canvas is amber.
2. Ping **PC3** (`10.0.0.3`) from **PC2**. It works across the loop.
3. Shut down the root port of the switch that is *not* blocking (its
   `Gi0/1`). Wait a few seconds: the blocked port takes over. Ping again.
4. In **Simulation**, tick **STP** to watch the BPDUs themselves.
''',
  );
  final s1 = place(lab, L2Switch('d1', hostname: 'S1'), 500, 120);
  final s2 = place(lab, L2Switch('d2', hostname: 'S2'), 300, 340);
  final s3 = place(lab, L2Switch('d3', hostname: 'S3'), 700, 340);
  final pc2 = place(lab, Pc('d4', hostname: 'PC2'), 300, 520);
  final pc3 = place(lab, Pc('d5', hostname: 'PC3'), 700, 520);
  lab.network
    ..connect(s1.port('Gi0/1')!, s2.port('Gi0/1')!)
    ..connect(s1.port('Gi0/2')!, s3.port('Gi0/1')!)
    ..connect(s2.port('Gi0/2')!, s3.port('Gi0/2')!)
    ..connect(pc2.nic, s2.port('Fa0/1')!)
    ..connect(pc3.nic, s3.port('Fa0/1')!);
  configure(s1, ['spanning-tree vlan 1 priority 4096']);
  for (final sw in [s2, s3]) {
    configure(sw, ['interface fa0/1', 'spanning-tree portfast']);
  }
  host(pc2, '10.0.0.2', '255.255.255.0');
  host(pc3, '10.0.0.3', '255.255.255.0');
  return lab;
}

Lab serialWan() {
  final lab = Lab(
    name: 'Serial WAN (troubleshooting)',
    notes: '''
# Serial WAN (troubleshooting)

Two branch routers joined by a serial link, each with a LAN. Everything is
addressed and routed, but **PC1 cannot reach PC2** (`192.168.2.10`).

Find out why:
- On **BR1**: `show ip interface brief`. Is `Serial0/0/0` up?
- A serial line needs a clock on its **DCE** end. The cable's first end,
  BR1's `S0/0/0`, is the DCE.

Fix: on BR1, `interface s0/0/0` then `clock rate 64000`. Then ping again
and run `tracert 192.168.2.10`.
''',
  );
  final br1 = place(lab, Router('d1', hostname: 'BR1'), 340, 200);
  final br2 = place(lab, Router('d2', hostname: 'BR2'), 760, 200);
  final pc1 = place(lab, Pc('d3', hostname: 'PC1'), 340, 440);
  final pc2 = place(lab, Pc('d4', hostname: 'PC2'), 760, 440);
  lab.network
    ..connect(br1.port('S0/0/0')!, br2.port('S0/0/0')!)
    ..connect(br1.port('Gi0/0')!, pc1.nic)
    ..connect(br2.port('Gi0/0')!, pc2.nic);
  configure(br1, [
    'interface s0/0/0',
    'ip address 10.0.0.1 255.255.255.252',
    'no shutdown',
    'interface g0/0',
    'ip address 192.168.1.1 255.255.255.0',
    'no shutdown',
    'exit',
    'ip route 192.168.2.0 255.255.255.0 10.0.0.2',
  ]);
  configure(br2, [
    'interface s0/0/0',
    'ip address 10.0.0.2 255.255.255.252',
    'no shutdown',
    'interface g0/0',
    'ip address 192.168.2.1 255.255.255.0',
    'no shutdown',
    'exit',
    'ip route 192.168.1.0 255.255.255.0 10.0.0.1',
  ]);
  host(pc1, '192.168.1.10', '255.255.255.0', '192.168.1.1');
  host(pc2, '192.168.2.10', '255.255.255.0', '192.168.2.1');
  return lab;
}
