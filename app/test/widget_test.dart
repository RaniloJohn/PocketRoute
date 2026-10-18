import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketroute/main.dart';
import 'package:pocketroute/src/lab/lab_controller.dart';
import 'package:pocketroute/src/lab/lab_store.dart';
import 'package:pocketroute/src/settings.dart';
import 'package:pocketroute/src/ui/console_window.dart';
import 'package:pocketroute/src/ui/lab_screen.dart';
import 'package:pocketroute_core/pocketroute_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('shell shows the menu bar, palette and status bar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const PocketRouteApp());
    expect(find.text('PocketRoute'), findsOneWidget);
    for (final label in ['File', 'View', 'Simulation', 'Router', 'L2 switch']) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    expect(find.text('0 devices, 0 cables'), findsOneWidget);

    await tester.tap(find.text('Router'));
    await tester.pump();
    expect(find.text('R1'), findsOneWidget);
    expect(find.text('1 devices, 0 cables'), findsOneWidget);
  });

  testWidgets('a landscape phone gets the compact layout', (tester) async {
    tester.view.physicalSize = const Size(914, 411);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const PocketRouteApp());
    // Menus fold into one button; no menu bar, no wide palette.
    expect(find.byType(MenuBar), findsNothing);
    expect(find.byIcon(Icons.menu), findsOneWidget);
    expect(find.text('END DEVICES'), findsNothing);
    expect(find.byTooltip('Add Router'), findsOneWidget);

    await tester.tap(find.byTooltip('Add L3 switch'));
    await tester.pump();
    expect(find.text('MLS1'), findsOneWidget);

    // A console opens as a sheet at the right edge with no dock button.
    final state = tester.state(find.byType(LabScreen)) as dynamic;
    (state.lab as LabController).openConsole(
      (state.lab as LabController).nodes.single,
      near: Offset.zero,
    );
    await tester.pump();
    expect(find.text('CLI'), findsOneWidget);
    expect(find.byTooltip('Dock below the canvas'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an upright phone lays out with the console at the bottom', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(411, 914);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const PocketRouteApp());
    final state = tester.state(find.byType(LabScreen)) as dynamic;
    final lab = state.lab as LabController;
    final sw = lab.addDevice(DeviceKind.l2switch, const Offset(200, 200));
    lab.openConsole(sw, near: Offset.zero);
    await tester.pump();
    expect(tester.takeException(), isNull);

    // The console spans the width, below the canvas's top part.
    final sheet = tester.getRect(find.byType(ConsoleWindowView));
    expect(sheet.width, greaterThan(300));
    expect(sheet.top, greaterThan(300));
  });

  test('the screen orientation choice is saved', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    expect((await AppSettings.load()).orientation, ScreenOrientation.landscape);
    await AppSettings().setOrientation(ScreenOrientation.portrait);
    expect((await AppSettings.load()).orientation, ScreenOrientation.portrait);
  });

  testWidgets('every starter lab opens in the lab controller', (tester) async {
    final store = LabStore();
    for (final starter in starterLabs) {
      final lab = LabController(lab: await store.loadStarter(starter));
      expect(lab.nodes, isNotEmpty, reason: starter.title);
      expect(lab.name, isNot('Untitled lab'), reason: starter.title);
      expect(lab.notes, isNotEmpty, reason: starter.title);
    }
    final campus = LabController(lab: await store.loadStarter(starterLabs[2]));
    expect(campus.nodes.map((n) => n.kind), contains(DeviceKind.l3switch));
    // New devices get fresh ids and names next to loaded ones.
    final added = campus.addDevice(DeviceKind.pc, Offset.zero);
    expect(added.device.id, 'd9');
    expect(added.name, 'PC4');
  });

  test('a lab saved from the controller reopens with positions', () {
    final lab = LabController();
    final sw = lab.addDevice(DeviceKind.l2switch, const Offset(300, 100));
    lab.addDevice(DeviceKind.server, const Offset(500, 300));
    lab
      ..setTool(Tool.cable)
      ..pickCablePort(lab.firstUsablePort(lab.nodes.last)!)
      ..pickCablePort(lab.firstUsablePort(sw)!)
      ..name = 'Mine';
    final bytes = LabFile.write(lab.toLab());
    final reopened = LabController(lab: LabFile.read(bytes));
    expect(reopened.name, 'Mine');
    expect(reopened.nodes.map((n) => (n.name, n.kind, n.position)), [
      ('SW1', DeviceKind.l2switch, const Offset(300, 100)),
      ('SRV1', DeviceKind.server, const Offset(500, 300)),
    ]);
    expect(reopened.network.links, hasLength(1));
  });

  test('saved file names are made safe', () {
    expect(LabStore.safeFileName('My lab: VLANs/2'), 'My lab VLANs2');
    expect(LabStore.safeFileName('   '), 'Untitled lab');
  });

  test('lab controller cables two devices and opens consoles', () {
    final lab = LabController();
    final pc = lab.addDevice(DeviceKind.pc, const Offset(100, 100));
    final sw = lab.addDevice(DeviceKind.l2switch, const Offset(300, 100));
    lab
      ..setTool(Tool.cable)
      ..pickCablePort(lab.firstUsablePort(pc)!)
      ..pickCablePort(lab.firstUsablePort(sw)!);
    expect(lab.network.links.single.cable, CableType.copperStraight);

    final window = lab.openConsole(sw, near: Offset.zero);
    window.terminal.submit('enable');
    expect(window.terminal.lines.last, 'SW1>enable');
    expect(window.terminal.backend.prompt, 'SW1#');
  });

  test('the palette L3 switch is a working multilayer switch', () {
    final lab = LabController();
    final core = lab.addDevice(DeviceKind.l3switch, Offset.zero);
    expect(core.device, isA<MultilayerSwitch>());
    expect(core.name, 'MLS1');
    final window = lab.openConsole(core, near: Offset.zero);
    window.terminal
      ..submit('enable')
      ..submit('conf t')
      ..submit('ip routing');
    expect((core.device as MultilayerSwitch).ipRouting, isTrue);
  });

  test('simulation mode steps through a ping frame by frame', () {
    final lab = LabController();
    final sw = lab.addDevice(DeviceKind.l2switch, const Offset(300, 100));
    final pc1 = lab.addDevice(DeviceKind.pc, const Offset(100, 300));
    final pc2 = lab.addDevice(DeviceKind.pc, const Offset(500, 300));
    lab.setTool(Tool.cable);
    for (final pc in [pc1, pc2]) {
      lab
        ..pickCablePort(lab.firstUsablePort(pc)!)
        ..pickCablePort(lab.firstUsablePort(sw)!);
    }
    lab.advance(10000);
    final t1 = lab.openConsole(pc1, near: Offset.zero).terminal;
    lab
        .openConsole(pc2, near: Offset.zero)
        .terminal
        .submit('ipconfig 10.0.0.2 255.255.255.0');
    t1.submit('ipconfig 10.0.0.1 255.255.255.0');

    lab.setSimulation(true);
    expect(lab.running, isFalse);
    t1.submit('ping -n 1 10.0.0.2');

    // Each step moves to the next tick that puts a frame on a cable.
    expect(lab.step(), isTrue);
    expect(lab.simEvents.single.description, startsWith('ARP request'));
    expect(lab.simEvents.single.from, 'PC1 Fa0');
    expect(lab.simEvents.single.to, 'SW1 Fa0/1');
    expect(lab.packets, hasLength(1));
    lab.step(); // flooded to PC2
    lab.step(); // ARP reply
    expect(lab.simEvents.last.description, startsWith('ARP reply'));
    while (t1.backend.busy && lab.step()) {}
    final icmp = lab.simEvents.where((e) => e.kind == FrameKind.icmp);
    expect(icmp, hasLength(4)); // request and reply, each over two cables
    expect(lab.simEvents.where((e) => e.kind == FrameKind.stp), isEmpty);
    expect(t1.lines.join('\n'), contains('Received = 1'));

    lab.setSimulation(false);
    expect(lab.running, isTrue);
    expect(lab.network.onTransmit, isNull);
  });

  test('two PCs ping through a switch using their console terminals', () {
    final lab = LabController();
    final sw = lab.addDevice(DeviceKind.l2switch, const Offset(300, 100));
    final pc1 = lab.addDevice(DeviceKind.pc, const Offset(100, 300));
    final pc2 = lab.addDevice(DeviceKind.pc, const Offset(500, 300));
    lab.setTool(Tool.cable);
    for (final pc in [pc1, pc2]) {
      lab
        ..pickCablePort(lab.firstUsablePort(pc)!)
        ..pickCablePort(lab.firstUsablePort(sw)!);
    }
    lab.advance(10000); // spanning tree brings the ports to forwarding

    final t1 = lab.openConsole(pc1, near: Offset.zero).terminal;
    final t2 = lab.openConsole(pc2, near: Offset.zero).terminal;
    t2.submit('ipconfig 192.168.1.11 255.255.255.0');
    t1
      ..submit('ipconfig 192.168.1.10 255.255.255.0')
      ..submit('ping -n 2 192.168.1.11');
    expect(t1.backend.busy, isTrue);
    for (var i = 0; i < 100 && t1.backend.busy; i++) {
      lab.advance(100);
    }
    final output = t1.lines.join('\n');
    expect(output, contains('Reply from 192.168.1.11'));
    expect(output, contains('Sent = 2, Received = 2'));
  });
}
