import 'package:flutter/material.dart';
import 'package:pocketroute_core/pocketroute_core.dart';

import '../lab/lab_controller.dart';
import '../theme.dart';
import 'terminal_view.dart';

/// Wide enough for 80-column device output at the terminal font size.
const consoleSize = Size(660, 440);
const dockedHeight = 300.0;

/// A device's console: floats (drag by the title bar), docks under the
/// canvas, or minimizes to the status bar.
class ConsoleWindowView extends StatelessWidget {
  const ConsoleWindowView({
    super.key,
    required this.lab,
    required this.window,
    required this.area,
    this.compact = false,
  });

  final LabController lab;
  final ConsoleWindow window;

  /// The space windows live in (the canvas area).
  final Size area;

  /// Phone layout: a sheet at the right edge (bottom edge when upright); no
  /// dragging or docking.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final docked = window.mode == WindowMode.docked;
    final ShapeBorder shape = compact
        ? area.height > area.width
              ? const Border(top: BorderSide(color: Tokens.windowBorder))
              : const Border(left: BorderSide(color: Tokens.windowBorder))
        : docked
        ? const Border(top: BorderSide(color: Tokens.windowBorder))
        : const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(Tokens.radius)),
            side: BorderSide(color: Tokens.windowBorder),
          );
    final body = Material(
      color: Colors.white,
      elevation: docked ? 0 : 6,
      shadowColor: const Color(0x401B2129),
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: Listener(
        onPointerDown: (_) => lab.bringToFront(window),
        child: Column(
          children: [
            _TitleBar(lab: lab, window: window, area: area, compact: compact),
            Expanded(
              child: _Tabs(lab: lab, window: window),
            ),
          ],
        ),
      ),
    );
    return body;
  }

  /// Keeps a floating window inside [area].
  static Offset clamp(Offset p, Size area) => Offset(
    p.dx.clamp(0, (area.width - consoleSize.width).clamp(0, double.infinity)),
    p.dy.clamp(0, (area.height - consoleSize.height).clamp(0, double.infinity)),
  );
}

class _TitleBar extends StatelessWidget {
  const _TitleBar({
    required this.lab,
    required this.window,
    required this.area,
    required this.compact,
  });

  final LabController lab;
  final ConsoleWindow window;
  final Size area;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final floating = !compact && window.mode == WindowMode.floating;
    Widget control(String tip, IconData icon, VoidCallback onTap) => Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(3),
        child: SizedBox.square(
          dimension: 30,
          child: Icon(icon, size: 16, color: const Color(0xFF3A4452)),
        ),
      ),
    );
    return GestureDetector(
      onPanUpdate: floating
          ? (d) => window.update(
              () => window.position = ConsoleWindowView.clamp(
                window.position + d.delta,
                area,
              ),
            )
          : null,
      child: MouseRegion(
        cursor: floating ? SystemMouseCursors.move : MouseCursor.defer,
        child: Container(
          height: 34,
          padding: const EdgeInsets.only(left: 10, right: 2),
          decoration: const BoxDecoration(
            color: Tokens.chromeAlt,
            border: Border(bottom: BorderSide(color: Tokens.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    text: window.node.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    children: [
                      TextSpan(
                        text: '  ${window.node.kind.label}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w400,
                          color: Tokens.muted,
                        ),
                      ),
                    ],
                  ),
                  style: const TextStyle(fontSize: 12.5),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              control(
                'Minimize',
                Icons.minimize,
                () => lab.setWindowMode(window, WindowMode.minimized),
              ),
              if (compact)
                const SizedBox.shrink()
              else if (floating)
                control(
                  'Dock below the canvas',
                  Icons.vertical_align_bottom,
                  () => lab.setWindowMode(window, WindowMode.docked),
                )
              else
                control(
                  'Float as a window',
                  Icons.open_in_new,
                  () => lab.setWindowMode(window, WindowMode.floating),
                ),
              control('Close', Icons.close, () => lab.closeConsole(window)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs({required this.lab, required this.window});

  final LabController lab;
  final ConsoleWindow window;

  @override
  Widget build(BuildContext context) {
    final device = window.node.device;
    final tabs = <(String, Widget Function())>[
      if (device is Pc) ...[
        ('Command prompt', () => TerminalView(buffer: window.terminal)),
        ('IP settings', () => _IpSettings(window: window)),
        (
          'Terminal',
          () => switch (lab.consoleTerminalFor(window)) {
            final terminal? => TerminalView(buffer: terminal),
            null => const _Empty(
              'Connect a console cable from this host\'s RS232 port to a '
              'router or switch console port to configure it from here.',
            ),
          },
        ),
      ] else ...[
        ('CLI', () => TerminalView(buffer: window.terminal)),
        ('Config', () => _ConfigText(lab: lab, window: window)),
        ('Ports', () => _PortTable(lab: lab, device: device)),
      ],
    ];
    return ListenableBuilder(
      listenable: window,
      builder: (context, _) {
        final current = window.tab.clamp(0, tabs.length - 1);
        return Column(
          children: [
            Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Tokens.border)),
              ),
              child: Row(
                children: [
                  for (final (i, (label, _)) in tabs.indexed)
                    InkWell(
                      onTap: () => window.update(() => window.tab = i),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              width: 2,
                              color: i == current
                                  ? Tokens.accent
                                  : Colors.transparent,
                            ),
                          ),
                        ),
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: i == current
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: i == current ? Tokens.ink : Tokens.muted,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(child: tabs[current].$2()),
          ],
        );
      },
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Text(
      text,
      style: const TextStyle(fontSize: 13, color: Tokens.muted),
    ),
  );
}

class _ConfigText extends StatelessWidget {
  const _ConfigText({required this.lab, required this.window});

  final LabController lab;
  final ConsoleWindow window;

  @override
  Widget build(BuildContext context) {
    final device = window.node.device as ConfigurableDevice;
    return ListenableBuilder(
      listenable: Listenable.merge([window.terminal, lab.ticks]),
      builder: (context, _) => Container(
        color: const Color(0xFFFBFCFD),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: SelectableText(
            device.renderConfig(),
            style: const TextStyle(
              fontFamily: Tokens.mono,
              fontSize: 12,
              height: 1.45,
              color: Tokens.ink,
            ),
          ),
        ),
      ),
    );
  }
}

class _PortTable extends StatelessWidget {
  const _PortTable({required this.lab, required this.device});

  final LabController lab;
  final Device device;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([lab, lab.ticks]),
      builder: (context, _) {
        final ports = device.allPorts.toList();
        TextStyle cell([Color color = Tokens.ink]) =>
            TextStyle(fontSize: 12, color: color);
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: ports.length + 1,
          separatorBuilder: (_, _) =>
              const Divider(height: 1, color: Color(0xFFE8EBEF)),
          itemBuilder: (context, i) {
            if (i == 0) {
              return _row(const [
                'Port',
                'Status',
                'Cable',
                'Connected to',
              ], List.filled(4, cell(Tokens.faint)));
            }
            final port = ports[i - 1];
            final link = port.link;
            final peer = port.peer;
            final status = link == null
                ? 'not cabled'
                : !port.adminUp
                ? 'admin down'
                : port.isUp
                ? 'up'
                : 'down';
            return _row(
              [
                port.name,
                status,
                link == null ? '' : _cableLabel(link.cable),
                peer == null
                    ? ''
                    : '${lab.nodeFor(peer.device)?.name} ${peer.shortName}',
              ],
              [
                cell(),
                cell(switch (status) {
                  'up' => Tokens.linkUp,
                  'down' || 'admin down' => Tokens.linkDown,
                  _ => Tokens.muted,
                }),
                cell(Tokens.muted),
                cell(),
              ],
            );
          },
        );
      },
    );
  }

  static String _cableLabel(CableType type) => switch (type) {
    CableType.copperStraight => 'straight',
    CableType.copperCross => 'crossover',
    CableType.serial => 'serial',
    CableType.console => 'console',
  };

  Widget _row(List<String> cells, List<TextStyle> styles) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    child: Row(
      children: [
        for (final (i, text) in cells.indexed)
          Expanded(
            flex: const [5, 3, 3, 5][i],
            child: Text(
              text,
              style: styles[i],
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    ),
  );
}

/// A form for a host's address; applies it through the command prompt so
/// the change shows in its history, as if typed.
class _IpSettings extends StatefulWidget {
  const _IpSettings({required this.window});

  final ConsoleWindow window;

  @override
  State<_IpSettings> createState() => _IpSettingsState();
}

class _IpSettingsState extends State<_IpSettings> {
  late final Pc pc = widget.window.node.device as Pc;
  late final _ip = TextEditingController(text: pc.ip.address?.toString());
  late final _mask = TextEditingController(
    text: pc.ip.mask?.toString() ?? '255.255.255.0',
  );
  late final _gateway = TextEditingController(text: pc.ip.gateway?.toString());
  String? _result;

  @override
  void dispose() {
    _ip.dispose();
    _mask.dispose();
    _gateway.dispose();
    super.dispose();
  }

  void _apply() {
    final terminal = widget.window.terminal;
    final before = terminal.lines.length;
    final command = [
      'ipconfig',
      _ip.text.trim(),
      _mask.text.trim(),
      if (_gateway.text.trim().isNotEmpty) _gateway.text.trim(),
    ].join(' ');
    terminal.submit(command);
    final output = terminal.lines.skip(before + 1).join(' ').trim();
    setState(() => _result = output.isEmpty ? 'Applied' : output);
  }

  @override
  Widget build(BuildContext context) {
    Widget field(String label, TextEditingController c) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: const TextStyle(fontSize: 13)),
          ),
          Expanded(
            child: TextField(
              controller: c,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              style: const TextStyle(fontSize: 13, fontFamily: Tokens.sans),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 9,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.all(
                    Radius.circular(Tokens.radius),
                  ),
                  borderSide: BorderSide(color: Tokens.control),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          field('IPv4 address', _ip),
          field('Subnet mask', _mask),
          field('Default gateway', _gateway),
          Row(
            children: [
              const SizedBox(width: 110),
              FilledButton(
                onPressed: _apply,
                style: FilledButton.styleFrom(
                  backgroundColor: Tokens.accent,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(
                      Radius.circular(Tokens.radius),
                    ),
                  ),
                  minimumSize: const Size(88, 36),
                ),
                child: const Text('Apply'),
              ),
              const SizedBox(width: 12),
              if (_result != null)
                Expanded(
                  child: Text(
                    _result!,
                    style: const TextStyle(fontSize: 12, color: Tokens.muted),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
