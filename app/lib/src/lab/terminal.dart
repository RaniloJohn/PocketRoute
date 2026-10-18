import 'package:flutter/foundation.dart';
import 'package:pocketroute_core/pocketroute_core.dart';

/// What a terminal talks to: an IOS-style CLI session or a PC command prompt.
abstract interface class TerminalBackend {
  String get prompt;
  bool get busy;
  void execute(String line);

  /// Completes the last word, or null.
  String? complete(String line);

  /// Leaves configuration mode (no-op where it means nothing).
  void ctrlZ();
}

class CliBackend implements TerminalBackend {
  CliBackend(this.session);

  final CliSession session;

  @override
  String get prompt => session.prompt;

  @override
  bool get busy => session.busy;

  @override
  void execute(String line) => session.execute(line);

  @override
  String? complete(String line) => session.complete(line);

  @override
  void ctrlZ() => session.ctrlZ();
}

class PcBackend implements TerminalBackend {
  PcBackend(this.shell);

  final PcShell shell;

  @override
  String get prompt => shell.prompt;

  @override
  bool get busy => shell.busy;

  @override
  void execute(String line) => shell.execute(line);

  @override
  String? complete(String line) => null;

  @override
  void ctrlZ() {}
}

/// Scrollback for one terminal: complete lines plus the line being printed.
/// Keeps the last [maxLines] lines.
class TerminalBuffer extends ChangeNotifier {
  TerminalBuffer({this.maxLines = 2000});

  final int maxLines;
  final _lines = <String>[];
  String _partial = '';
  late TerminalBackend backend;
  final history = <String>[];

  List<String> get lines => _lines;

  /// Text printed since the last newline (e.g. ping marks).
  String get partial => _partial;

  /// Appends output from the device.
  void write(String text) {
    final parts = (_partial + text).split('\n');
    _partial = parts.removeLast();
    _lines.addAll(parts);
    if (_lines.length > maxLines) {
      _lines.removeRange(0, _lines.length - maxLines);
    }
    notifyListeners();
  }

  /// Echoes [line] after the prompt, then runs it.
  void submit(String line) {
    write('${backend.prompt}$line\n');
    if (line.trim().isNotEmpty && !line.endsWith('?')) history.add(line);
    backend.execute(line);
    notifyListeners();
  }

  /// Runs `line?` for help; the caller keeps [line] in the input box.
  void help(String line) {
    write('${backend.prompt}$line?\n');
    backend.execute('$line?');
    notifyListeners();
  }

  void ctrlZ() {
    write('${backend.prompt}^Z\n');
    backend.ctrlZ();
    notifyListeners();
  }

  void clear() {
    _lines.clear();
    _partial = '';
    notifyListeners();
  }
}
