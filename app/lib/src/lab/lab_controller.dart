import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:pocketroute_core/pocketroute_core.dart';

import '../theme.dart';
import 'terminal.dart';

/// Device types offered in the palette.
enum DeviceKind {
  router('Router', 'R', 'router'),
  l2switch('L2 switch', 'SW', 'switch_l2'),
  l3switch('L3 switch', 'MLS', 'switch_l3'),
  pc('PC', 'PC', 'pc'),
  laptop('Laptop', 'LAP', 'laptop'),
  server('Server', 'SRV', 'server');

  const DeviceKind(this.label, this.namePrefix, this.asset);

  final String label;
  final String namePrefix;
  final String asset;

  bool get isHost => this == pc || this == laptop || this == server;
}

/// Cable choices in the palette. [auto] lets the engine pick.
enum CableChoice {
  auto('Automatic', null),
  straight('Straight-through', CableType.copperStraight),
  cross('Crossover', CableType.copperCross),
  serial('Serial', CableType.serial),
  console('Console', CableType.console);

  const CableChoice(this.label, this.type);

  final String label;
  final CableType? type;
}

enum Tool { select, cable, note, delete }

enum WindowMode { floating, docked, minimized }

/// A device placed on the canvas. [position] is its centre in scene units.
class NodeView {
  NodeView(this.device, this.kind, this.position);

  final Device device;
  final DeviceKind kind;
  Offset position;

  String get name => device.hostname;
}

/// One frame in the simulation event list.
class SimEvent {
  const SimEvent({
    required this.time,
    required this.from,
    required this.to,
    required this.description,
    required this.kind,
  });

  /// Simulated milliseconds.
  final int time;
  final String from;
  final String to;
  final String description;
  final FrameKind kind;
}

/// A frame drawn travelling along its cable.
class PacketAnimation {
  const PacketAnimation(this.from, this.to, this.kind, this.start);

  final NodeView from;
  final NodeView to;
  final FrameKind kind;

  /// [LabController.animationNow] when it set off.
  final int start;
}

/// One console window and its terminal.
class ConsoleWindow extends ChangeNotifier {
  ConsoleWindow(this.node, this.terminal, {required this.position});

  final NodeView node;
  final TerminalBuffer terminal;

  /// Second terminal for a host's console cable, created on demand.
  TerminalBuffer? consoleTerminal;
  WindowMode mode = WindowMode.floating;
  Offset position;
  int tab = 0;

  void update(void Function() change) {
    change();
    notifyListeners();
  }
}

/// Everything about the open lab: the simulated network, where devices sit,
/// the current tool, open consoles and view options.
class LabController extends ChangeNotifier {
  LabController();

  final network = Network();
  final nodes = <NodeView>[];
  final consoles = <ConsoleWindow>[];

  /// Bumped whenever simulated time moves; canvas painters listen to it.
  final ticks = ValueNotifier<int>(0);

  Tool tool = Tool.select;
  CableChoice cable = CableChoice.auto;
  NodeView? selected;

  /// First end of a cable being drawn.
  Port? cableStart;

  CanvasPattern pattern = CanvasPattern.grid;
  CanvasTheme canvasTheme = CanvasTheme.light;
  bool showPortLabels = true;
  bool snapToGrid = true;
  bool running = true;

  /// Short feedback shown in the status bar.
  String? message;

  final _counters = <DeviceKind, int>{};
  int _nextId = 1;

  int get simMillis => network.scheduler.now;

  CanvasColors get colors => CanvasColors.of(canvasTheme);

  void _changed() => notifyListeners();

  void setTool(Tool value) {
    tool = value;
    cableStart = null;
    message = switch (value) {
      Tool.cable => 'Cable: tap the first device',
      Tool.delete => 'Delete: tap a device or cable',
      Tool.note => 'Notes are coming in a later version',
      Tool.select => null,
    };
    _changed();
  }

  void setCable(CableChoice value) {
    cable = value;
    if (tool != Tool.cable) setTool(Tool.cable);
    _changed();
  }

  void setView({
    CanvasPattern? pattern,
    CanvasTheme? theme,
    bool? portLabels,
    bool? snap,
  }) {
    if (pattern != null) this.pattern = pattern;
    if (theme != null) canvasTheme = theme;
    if (portLabels != null) showPortLabels = portLabels;
    if (snap != null) snapToGrid = snap;
    _changed();
  }

  void setRunning(bool value) {
    running = value;
    if (value) _leaveSimulation();
    _changed();
  }

  // --- Simulation mode -------------------------------------------------

  /// Simulation mode: the clock stops and time moves one step at a time,
  /// with every frame listed and animated along its cable.
  bool simulation = false;

  /// Steps automatically while true.
  bool simPlaying = false;

  /// Spanning tree BPDUs are constant background chatter; hidden by default.
  bool showStp = false;
  final simEvents = <SimEvent>[];
  final packets = <PacketAnimation>[];
  final _pending = <Transit>[];
  final _clock = Stopwatch()..start();

  static const maxEvents = 500;
  static const packetMillis = 550;

  /// Wall-clock milliseconds, for animation only.
  int get animationNow => _clock.elapsedMilliseconds;

  void setSimulation(bool value) {
    if (value == simulation) return;
    if (value) {
      simulation = true;
      running = false;
      network.onTransmit = _record;
      message = 'Simulation: press Step, or Play, then ping from a PC';
    } else {
      _leaveSimulation();
      running = true;
    }
    _changed();
  }

  void _leaveSimulation() {
    simulation = false;
    simPlaying = false;
    network.onTransmit = null;
    _pending.clear();
    packets.clear();
  }

  void setSimPlaying(bool value) {
    simPlaying = value;
    _changed();
  }

  void setShowStp(bool value) {
    showStp = value;
    _changed();
  }

  void clearEvents() {
    simEvents.clear();
    _changed();
  }

  void _record(Transit transit) {
    if (!showStp && transit.kind == FrameKind.stp) return;
    _pending.add(transit);
  }

  /// Shows the next batch of visible frames: those already sent, or else
  /// runs simulated time up to the next tick that sends one. Records them
  /// and starts their animations. Returns false if nothing visible happened
  /// within [maxTicks] steps.
  bool step({int maxTicks = 500}) {
    // Frames sent since the last step (e.g. by a ping typed in a console)
    // are already on their cables: show those before running time on.
    for (var i = 0; i < maxTicks && _pending.isEmpty; i++) {
      if (!network.scheduler.step()) break;
    }
    final start = animationNow;
    for (final transit in _pending) {
      final from = nodeFor(transit.from.device);
      final to = nodeFor(transit.to.device);
      if (from == null || to == null) continue;
      simEvents.add(
        SimEvent(
          time: transit.sentAt,
          from: '${from.name} ${transit.from.shortName}',
          to: '${to.name} ${transit.to.shortName}',
          description: transit.description,
          kind: transit.kind,
        ),
      );
      packets.add(PacketAnimation(from, to, transit.kind, start));
    }
    if (simEvents.length > maxEvents) {
      simEvents.removeRange(0, simEvents.length - maxEvents);
    }
    final moved = _pending.isNotEmpty;
    message = moved
        ? null
        : 'Nothing is being sent. Start a ping from a PC console, then Step.';
    if (!moved) simPlaying = false;
    _pending.clear();
    ticks.value++;
    _changed();
    return moved;
  }

  /// Drops finished animations; true while any are still moving.
  bool pruneAnimations() {
    final now = animationNow;
    packets.removeWhere((p) => now - p.start > packetMillis);
    return packets.isNotEmpty;
  }

  /// Moves simulated time forward by [millis].
  void advance(int millis) {
    if (millis <= 0) return;
    network.scheduler.advance(millis);
    ticks.value++;
  }

  NodeView? nodeFor(Device device) {
    for (final node in nodes) {
      if (identical(node.device, device)) return node;
    }
    return null;
  }

  NodeView addDevice(DeviceKind kind, Offset position) {
    final count = (_counters[kind] ?? 0) + 1;
    _counters[kind] = count;
    final id = 'd${_nextId++}';
    final name = '${kind.namePrefix}$count';
    final Device device = switch (kind) {
      DeviceKind.router => Router(id, hostname: name),
      DeviceKind.l2switch => L2Switch(id, hostname: name),
      DeviceKind.l3switch => MultilayerSwitch(id, hostname: name),
      DeviceKind.pc => Pc(id, hostname: name),
      DeviceKind.laptop => Pc(id, hostname: name, kind: HostKind.laptop),
      DeviceKind.server => Pc(id, hostname: name, kind: HostKind.server),
    };
    network.add(device);
    // Step right (then down) until the spot is clear of other devices.
    var spot = position;
    for (var i = 0; i < 40 && _occupied(spot); i++) {
      spot += i % 6 == 5 ? const Offset(-600, 140) : const Offset(120, 0);
    }
    final node = NodeView(device, kind, _snap(spot));
    nodes.add(node);
    selected = node;
    message = 'Added $name';
    _changed();
    return node;
  }

  bool _occupied(Offset p) => nodes.any((n) => (n.position - p).distance < 90);

  void moveDevice(NodeView node, Offset position, {bool finished = false}) {
    node.position = finished ? _snap(position) : position;
    _changed();
  }

  Offset _snap(Offset p) {
    if (!snapToGrid) return p;
    const step = 20.0;
    return Offset(
      (p.dx / step).roundToDouble() * step,
      (p.dy / step).roundToDouble() * step,
    );
  }

  void select(NodeView? node) {
    selected = node;
    _changed();
  }

  void removeDevice(NodeView node) {
    for (final window in consoles.where((w) => w.node == node).toList()) {
      closeConsole(window);
    }
    network.remove(node.device);
    nodes.remove(node);
    if (selected == node) selected = null;
    message = 'Deleted ${node.name}';
    _changed();
  }

  void removeLink(Link link) {
    network.disconnect(link);
    message = 'Removed cable ${link.a.shortName} - ${link.b.shortName}';
    _changed();
  }

  /// Ports of [node] a new cable could use, given the cable choice and the
  /// first end already picked. Free ports only.
  bool portUsable(Port port) {
    if (port.link != null) return false;
    final start = cableStart;
    final type = cable.type;
    if (start == null) {
      return type == null || _mediumFits(type, port.medium);
    }
    if (identical(start.device, port.device)) return false;
    return type == null
        ? Network.cableFor(start, port) != null
        : Network.fits(type, start, port);
  }

  static bool _mediumFits(CableType type, PortMedium medium) => switch (type) {
    CableType.copperStraight ||
    CableType.copperCross => medium == PortMedium.ethernet,
    CableType.serial => medium == PortMedium.serial,
    CableType.console =>
      medium == PortMedium.console || medium == PortMedium.rs232,
  };

  /// First free port that would work, for automatic cabling.
  Port? firstUsablePort(NodeView node) {
    for (final port in node.device.allPorts) {
      if (portUsable(port)) return port;
    }
    return null;
  }

  /// Picks [port] as the start or the end of the cable being drawn.
  void pickCablePort(Port port) {
    final start = cableStart;
    if (start == null) {
      cableStart = port;
      message =
          'Cable from ${nodeFor(port.device)?.name} ${port.shortName}: '
          'tap the other device';
      _changed();
      return;
    }
    try {
      final link = network.connect(start, port, cable: cable.type);
      message =
          'Connected ${start.shortName} to ${port.shortName} '
          '(${_cableName(link.cable)})';
      if (!link.works && link.cable != CableType.console) {
        message =
            '$message. The link is down: '
            '${link.cable == CableType.serial ? 'set a clock rate on the DCE end' : 'wrong cable type for these devices'}';
      }
    } on ArgumentError catch (e) {
      message = '${e.message}';
    }
    cableStart = null;
    ticks.value++;
    _changed();
  }

  void cancelCable() {
    cableStart = null;
    message = tool == Tool.cable ? 'Cable: tap the first device' : null;
    _changed();
  }

  static String _cableName(CableType type) => switch (type) {
    CableType.copperStraight => 'straight-through',
    CableType.copperCross => 'crossover',
    CableType.serial => 'serial',
    CableType.console => 'console',
  };

  /// Opens (or brings back) the console window for [node].
  ConsoleWindow openConsole(NodeView node, {required Offset near}) {
    for (final window in consoles) {
      if (window.node == node) {
        window.update(() {
          if (window.mode == WindowMode.minimized) {
            window.mode = WindowMode.floating;
          }
        });
        consoles
          ..remove(window)
          ..add(window);
        _changed();
        return window;
      }
    }
    final terminal = TerminalBuffer();
    final device = node.device;
    terminal.backend = switch (device) {
      final Pc pc => PcBackend(PcShell(pc, write: terminal.write)),
      final ConfigurableDevice d => CliBackend(d.openCli(terminal.write)),
      _ => throw StateError('No console for ${device.runtimeType}'),
    };
    if (device is Pc) {
      terminal.write('PocketRoute command prompt. Type help for commands.\n\n');
    } else {
      terminal.write('\nPress RETURN to get started.\n\n');
    }
    final offset = consoles.length * 28.0;
    final window = ConsoleWindow(
      node,
      terminal,
      position: Offset(near.dx + offset, math.max(8, near.dy + offset)),
    );
    consoles.add(window);
    _changed();
    return window;
  }

  /// A terminal on whatever [window]'s host is console-cabled to.
  TerminalBuffer? consoleTerminalFor(ConsoleWindow window) {
    final device = window.node.device;
    if (device is! Pc) return null;
    if (device.consoleTarget case final ConfigurableDevice target) {
      return window.consoleTerminal ??= _consoleTerminal(target);
    }
    return null;
  }

  TerminalBuffer _consoleTerminal(ConfigurableDevice target) {
    final terminal = TerminalBuffer();
    terminal.backend = CliBackend(target.openCli(terminal.write));
    terminal.write('Connected to ${target.hostname} console.\n\n');
    return terminal;
  }

  /// Changes how [window] is shown. One console docks at a time; docking
  /// another floats the previous one.
  void setWindowMode(ConsoleWindow window, WindowMode mode) {
    if (mode == WindowMode.docked) {
      for (final other in consoles) {
        if (other != window && other.mode == WindowMode.docked) {
          other.update(() => other.mode = WindowMode.floating);
        }
      }
    }
    window.update(() => window.mode = mode);
    if (mode != WindowMode.minimized) {
      consoles
        ..remove(window)
        ..add(window);
    }
    _changed();
  }

  void bringToFront(ConsoleWindow window) {
    if (consoles.last == window) return;
    consoles
      ..remove(window)
      ..add(window);
    _changed();
  }

  void closeConsole(ConsoleWindow window) {
    consoles.remove(window);
    _changed();
  }

  @override
  void dispose() {
    ticks.dispose();
    super.dispose();
  }
}
