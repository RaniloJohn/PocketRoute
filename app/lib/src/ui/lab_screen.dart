import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../lab/lab_controller.dart';
import '../theme.dart';
import 'canvas_view.dart';
import 'console_window.dart';
import 'device_glyph.dart';

/// The tablet layout: menu bar, palette, canvas with consoles, status bar.
class LabScreen extends StatefulWidget {
  const LabScreen({super.key});

  @override
  State<LabScreen> createState() => _LabScreenState();
}

class _LabScreenState extends State<LabScreen>
    with SingleTickerProviderStateMixin {
  LabController lab = LabController();
  final transform = TransformationController();
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  Size _canvasSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      final delta = (elapsed - _last).inMilliseconds;
      _last = elapsed;
      // Realtime: one simulated millisecond per real one, capped so a stall
      // does not dump seconds of traffic at once.
      if (lab.running) lab.advance(math.min(delta, 100));
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    transform.dispose();
    lab.dispose();
    super.dispose();
  }

  void _newLab() {
    final old = lab;
    setState(() => lab = LabController());
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  /// Centre of the visible canvas, in scene units.
  Offset get _viewCentre =>
      transform.toScene(Offset(_canvasSize.width / 2, _canvasSize.height / 2));

  void _zoom(double factor) {
    final centre = Offset(_canvasSize.width / 2, _canvasSize.height / 2);
    final scale = transform.value.getMaxScaleOnAxis();
    final target = (scale * factor).clamp(0.3, 2.5) / scale;
    transform.value = Matrix4.identity()
      ..translateByDouble(centre.dx, centre.dy, 0, 1)
      ..scaleByDouble(target, target, 1, 1)
      ..translateByDouble(-centre.dx, -centre.dy, 0, 1)
      ..multiply(transform.value);
    setState(() {});
  }

  void _fit() {
    if (lab.nodes.isEmpty || _canvasSize.isEmpty) {
      transform.value = Matrix4.identity();
      setState(() {});
      return;
    }
    var bounds = Rect.fromCenter(
      center: lab.nodes.first.position,
      width: 0,
      height: 0,
    );
    for (final node in lab.nodes) {
      bounds = bounds.expandToInclude(
        Rect.fromCenter(center: node.position, width: 120, height: 110),
      );
    }
    final scale = math
        .min(
          _canvasSize.width / bounds.width,
          _canvasSize.height / bounds.height,
        )
        .clamp(0.3, 1.5);
    final dx = _canvasSize.width / 2 - bounds.center.dx * scale;
    final dy = _canvasSize.height / 2 - bounds.center.dy * scale;
    transform.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
    setState(() {});
  }

  void _openConsole(NodeView node, Offset viewPosition) {
    lab.openConsole(node, near: viewPosition + const Offset(48, -60));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: lab,
          builder: (context, _) {
            final docked = lab.consoles
                .where((w) => w.mode == WindowMode.docked)
                .firstOrNull;
            return Column(
              children: [
                _Header(
                  lab: lab,
                  onNew: _newLab,
                  onAdd: (kind) => lab.addDevice(kind, _viewCentre),
                  onZoom: _zoom,
                  onFit: _fit,
                ),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Palette(
                        lab: lab,
                        onAdd: (kind) => lab.addDevice(kind, _viewCentre),
                      ),
                      Expanded(
                        child: Column(
                          children: [
                            Expanded(child: _canvasArea()),
                            if (docked != null)
                              SizedBox(
                                height: dockedHeight,
                                child: ConsoleWindowView(
                                  key: ObjectKey(docked),
                                  lab: lab,
                                  window: docked,
                                  area: _canvasSize,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                _StatusBar(
                  lab: lab,
                  transform: transform,
                  onZoom: _zoom,
                  onFit: _fit,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _canvasArea() {
    return LayoutBuilder(
      builder: (context, constraints) {
        _canvasSize = constraints.biggest;
        final floating = lab.consoles.where(
          (w) => w.mode == WindowMode.floating,
        );
        return ClipRect(
          child: Stack(
            children: [
              Positioned.fill(
                child: CanvasView(
                  lab: lab,
                  transform: transform,
                  onOpenConsole: _openConsole,
                ),
              ),
              for (final window in floating)
                ListenableBuilder(
                  key: ObjectKey(window),
                  listenable: window,
                  builder: (context, _) {
                    final pos = ConsoleWindowView.clamp(
                      window.position,
                      _canvasSize,
                    );
                    return Positioned(
                      left: pos.dx,
                      top: pos.dy,
                      width: consoleSize.width,
                      height: consoleSize.height,
                      child: ConsoleWindowView(
                        lab: lab,
                        window: window,
                        area: _canvasSize,
                      ),
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Text button used across the chrome: flat, 4 px corners.
class _ChromeButton extends StatelessWidget {
  const _ChromeButton({
    required this.label,
    required this.onTap,
    this.selected = false,
    this.first = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool selected;
  final bool first;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? Tokens.selected : Colors.white,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: first
                ? null
                : const Border(left: BorderSide(color: Tokens.control)),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
              color: selected ? Tokens.accentText : Tokens.text,
            ),
          ),
        ),
      ),
    );
  }
}

class _Segmented extends StatelessWidget {
  const _Segmented({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      border: Border.all(color: Tokens.control),
      borderRadius: BorderRadius.circular(Tokens.radius),
    ),
    clipBehavior: Clip.antiAlias,
    child: Row(mainAxisSize: MainAxisSize.min, children: children),
  );
}

class _Header extends StatelessWidget {
  const _Header({
    required this.lab,
    required this.onNew,
    required this.onAdd,
    required this.onZoom,
    required this.onFit,
  });

  final LabController lab;
  final VoidCallback onNew;
  final void Function(DeviceKind kind) onAdd;
  final void Function(double factor) onZoom;
  final VoidCallback onFit;

  @override
  Widget build(BuildContext context) {
    const menuText = TextStyle(fontSize: 13, color: Tokens.text);
    final topStyle = ButtonStyle(
      textStyle: const WidgetStatePropertyAll(menuText),
      foregroundColor: const WidgetStatePropertyAll(Tokens.text),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 10),
      ),
      minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
      shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
      backgroundColor: WidgetStateProperty.resolveWith(
        (s) =>
            s.contains(WidgetState.focused) ||
                s.contains(WidgetState.hovered) ||
                s.contains(WidgetState.pressed)
            ? Tokens.selected
            : Colors.transparent,
      ),
    );
    SubmenuButton menu(String label, List<Widget> items) =>
        SubmenuButton(style: topStyle, menuChildren: items, child: Text(label));
    MenuItemButton item(String label, VoidCallback? onTap) =>
        MenuItemButton(onPressed: onTap, child: Text(label));

    return Container(
      height: 44,
      padding: const EdgeInsets.only(left: 14, right: 10),
      decoration: const BoxDecoration(
        color: Tokens.chrome,
        border: Border(bottom: BorderSide(color: Tokens.border)),
      ),
      child: Row(
        children: [
          const Text(
            'PocketRoute',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 10),
          MenuBar(
            style: const MenuStyle(
              backgroundColor: WidgetStatePropertyAll(Colors.transparent),
              elevation: WidgetStatePropertyAll(0),
              shadowColor: WidgetStatePropertyAll(Colors.transparent),
              padding: WidgetStatePropertyAll(EdgeInsets.zero),
            ),
            children: [
              menu('File', [
                item('New lab', onNew),
                item('Open…  (next update)', null),
                item('Save  (next update)', null),
              ]),
              menu('Edit', [
                item(
                  'Delete selected',
                  lab.selected == null
                      ? null
                      : () => lab.removeDevice(lab.selected!),
                ),
              ]),
              menu('View', [
                for (final p in CanvasPattern.values)
                  RadioMenuButton<CanvasPattern>(
                    value: p,
                    groupValue: lab.pattern,
                    onChanged: (v) => lab.setView(pattern: v),
                    child: Text('${_title(p.name)} pattern'),
                  ),
                const Divider(height: 8),
                for (final t in CanvasTheme.values)
                  RadioMenuButton<CanvasTheme>(
                    value: t,
                    groupValue: lab.canvasTheme,
                    onChanged: (v) => lab.setView(theme: v),
                    child: Text('${_title(t.name)} canvas'),
                  ),
                const Divider(height: 8),
                CheckboxMenuButton(
                  value: lab.showPortLabels,
                  onChanged: (v) => lab.setView(portLabels: v),
                  child: const Text('Port labels on cables'),
                ),
                CheckboxMenuButton(
                  value: lab.snapToGrid,
                  onChanged: (v) => lab.setView(snap: v),
                  child: const Text('Snap to grid'),
                ),
                const Divider(height: 8),
                item('Zoom in', () => onZoom(1.25)),
                item('Zoom out', () => onZoom(0.8)),
                item('Fit to screen', onFit),
              ]),
              menu('Devices', [
                for (final kind in DeviceKind.values)
                  item('Add ${kind.label}', () => onAdd(kind)),
              ]),
              menu('Simulation', [
                RadioMenuButton<bool>(
                  value: true,
                  groupValue: lab.running,
                  onChanged: (_) => lab.setRunning(true),
                  child: const Text('Run in real time'),
                ),
                RadioMenuButton<bool>(
                  value: false,
                  groupValue: lab.running,
                  onChanged: (_) => lab.setRunning(false),
                  child: const Text('Pause'),
                ),
                item(
                  'Step 100 ms',
                  lab.running ? null : () => lab.advance(100),
                ),
              ]),
              menu('Help', [item('About PocketRoute', () => _about(context))]),
            ],
          ),
          // On narrow screens the tool groups scroll rather than overflow.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                children: [
                  _Segmented(
                    children: [
                      for (final (i, tool) in Tool.values.indexed)
                        _ChromeButton(
                          label: _title(tool.name),
                          first: i == 0,
                          selected: lab.tool == tool,
                          onTap: () => lab.setTool(tool),
                        ),
                    ],
                  ),
                  const SizedBox(width: 10),
                  _Segmented(
                    children: [
                      _ChromeButton(
                        label: 'Realtime',
                        first: true,
                        selected: lab.running,
                        onTap: () => lab.setRunning(true),
                      ),
                      _ChromeButton(
                        label: 'Paused',
                        selected: !lab.running,
                        onTap: () => lab.setRunning(false),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _title(String s) => s[0].toUpperCase() + s.substring(1);

  void _about(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(Tokens.radius)),
      ),
      title: const Text('PocketRoute', style: TextStyle(fontSize: 16)),
      content: const Text(
        'An offline network lab for students.\n\n'
        'PocketRoute is not affiliated with or endorsed by Cisco Systems, Inc.\n'
        'IBM Plex fonts: SIL Open Font License 1.1.',
        style: TextStyle(fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

class _Palette extends StatefulWidget {
  const _Palette({required this.lab, required this.onAdd});

  final LabController lab;
  final void Function(DeviceKind kind) onAdd;

  @override
  State<_Palette> createState() => _PaletteState();
}

class _PaletteState extends State<_Palette> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final lab = widget.lab;
    bool matches(String label) =>
        label.toLowerCase().contains(_filter.toLowerCase());
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
          color: Tokens.faint,
        ),
      ),
    );
    Widget device(DeviceKind kind) {
      final row = Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            DeviceGlyph(
              kind: kind,
              color: const Color(0xFF1A7CF0),
              fill: Tokens.chrome,
              size: 26,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(kind.label, style: const TextStyle(fontSize: 12.5)),
            ),
          ],
        ),
      );
      return Draggable<DeviceKind>(
        data: kind,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: Transform.translate(
          offset: const Offset(-28, -28),
          child: DeviceGlyph(
            kind: kind,
            color: const Color(0xFF1A7CF0),
            fill: Colors.white.withValues(alpha: 0.7),
          ),
        ),
        child: InkWell(onTap: () => widget.onAdd(kind), child: row),
      );
    }

    final network = [
      DeviceKind.router,
      DeviceKind.l2switch,
      DeviceKind.l3switch,
    ].where((k) => matches(k.label));
    final hosts = [
      DeviceKind.pc,
      DeviceKind.laptop,
      DeviceKind.server,
    ].where((k) => matches(k.label));

    return Container(
      width: 200,
      decoration: const BoxDecoration(
        color: Tokens.chrome,
        border: Border(right: BorderSide(color: Tokens.border)),
      ),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 10),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: SizedBox(
              height: 30,
              child: TextField(
                onChanged: (v) => setState(() => _filter = v),
                style: const TextStyle(fontSize: 12.5),
                decoration: const InputDecoration(
                  hintText: 'Search',
                  isDense: true,
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(
                      Radius.circular(Tokens.radius),
                    ),
                    borderSide: BorderSide(color: Tokens.control),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.all(
                      Radius.circular(Tokens.radius),
                    ),
                    borderSide: BorderSide(color: Tokens.control),
                  ),
                ),
              ),
            ),
          ),
          if (network.isNotEmpty) heading('Network'),
          ...network.map(device),
          if (hosts.isNotEmpty) heading('End devices'),
          ...hosts.map(device),
          heading('Cables'),
          for (final choice in CableChoice.values)
            Material(
              color: lab.tool == Tool.cable && lab.cable == choice
                  ? Tokens.selected
                  : Colors.transparent,
              child: InkWell(
                onTap: () => lab.setCable(choice),
                child: Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      CustomPaint(
                        size: const Size(34, 10),
                        painter: _CableSample(choice, lab.colors),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          choice.label,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CableSample extends CustomPainter {
  _CableSample(this.choice, this.colors);

  final CableChoice choice;
  final CanvasColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final light = CanvasColors.of(CanvasTheme.light);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = switch (choice) {
        CableChoice.serial => light.serial,
        CableChoice.console => light.console,
        _ => light.cable,
      };
    final y = size.height / 2;
    switch (choice) {
      case CableChoice.serial:
        canvas.drawPath(
          Path()
            ..moveTo(2, y)
            ..lineTo(11, y)
            ..lineTo(14, y - 3)
            ..lineTo(19, y + 3)
            ..lineTo(22, y)
            ..lineTo(32, y),
          paint,
        );
      case CableChoice.cross:
        for (var x = 2.0; x < 32; x += 10) {
          canvas.drawLine(Offset(x, y), Offset(x + 6, y), paint);
        }
      case CableChoice.console:
        for (var x = 2.0; x <= 32; x += 4) {
          canvas.drawCircle(Offset(x, y), 1, paint..style = PaintingStyle.fill);
        }
      case CableChoice.auto || CableChoice.straight:
        canvas.drawLine(Offset(2, y), Offset(32, y), paint);
    }
  }

  @override
  bool shouldRepaint(_CableSample old) => old.choice != choice;
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.lab,
    required this.transform,
    required this.onZoom,
    required this.onFit,
  });

  final LabController lab;
  final TransformationController transform;
  final void Function(double factor) onZoom;
  final VoidCallback onFit;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 11.5, color: Color(0xFF4A5563));
    Widget rule() => Container(
      width: 1,
      height: 14,
      margin: const EdgeInsets.symmetric(horizontal: 10),
      color: Tokens.border,
    );
    final minimized = lab.consoles.where((w) => w.mode == WindowMode.minimized);
    return Container(
      height: 28,
      padding: const EdgeInsets.only(left: 12, right: 6),
      decoration: const BoxDecoration(
        color: Tokens.chrome,
        border: Border(top: BorderSide(color: Tokens.border)),
      ),
      child: Row(
        children: [
          Text(lab.running ? 'Realtime' : 'Paused', style: style),
          rule(),
          ValueListenableBuilder(
            valueListenable: lab.ticks,
            builder: (context, _, _) => Text(
              _clock(lab.simMillis),
              style: style.copyWith(fontFamily: Tokens.mono),
            ),
          ),
          rule(),
          Text(
            '${lab.nodes.length} devices, ${lab.network.links.length} cables',
            style: style,
          ),
          if (minimized.isNotEmpty) rule(),
          for (final window in minimized)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: OutlinedButton(
                onPressed: () => lab.setWindowMode(window, WindowMode.floating),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 22),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  backgroundColor: Colors.white,
                  side: const BorderSide(color: Tokens.control),
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(3)),
                  ),
                  textStyle: const TextStyle(fontSize: 11.5),
                  foregroundColor: Tokens.ink,
                ),
                child: Text('${window.node.name} console'),
              ),
            ),
          if (lab.message != null) ...[
            rule(),
            Expanded(
              child: Text(
                lab.message!,
                style: style,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ] else
            const Spacer(),
          IconButton(
            tooltip: 'Zoom out',
            onPressed: () => onZoom(0.8),
            icon: const Text('−', style: TextStyle(fontSize: 14)),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
          SizedBox(
            width: 44,
            child: ListenableBuilder(
              listenable: transform,
              builder: (context, _) => Text(
                '${(transform.value.getMaxScaleOnAxis() * 100).round()}%',
                textAlign: TextAlign.center,
                style: style.copyWith(fontFamily: Tokens.mono),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Zoom in',
            onPressed: () => onZoom(1.25),
            icon: const Text('+', style: TextStyle(fontSize: 14)),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
          TextButton(
            onPressed: onFit,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 24),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              foregroundColor: Tokens.text,
              textStyle: const TextStyle(fontSize: 11.5),
            ),
            child: const Text('Fit'),
          ),
        ],
      ),
    );
  }

  static String _clock(int millis) {
    final s = millis ~/ 1000;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(s ~/ 3600)}:${two(s ~/ 60 % 60)}:${two(s % 60)}';
  }
}
