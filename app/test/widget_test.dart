import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketroute/main.dart';
import 'package:pocketroute/src/lab/lab_controller.dart';
import 'package:pocketroute/src/ui/lab_screen.dart';
import 'package:pocketroute_core/pocketroute_core.dart';

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
