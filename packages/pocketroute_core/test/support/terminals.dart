import 'package:pocketroute_core/pocketroute_core.dart';

typedef SwitchTerminal = CliTerminal;

/// Drives a switch or router console the way the terminal UI will.
class CliTerminal {
  CliTerminal(ConfigurableDevice device) {
    session = device.openCli(_out.write);
  }

  final _out = StringBuffer();
  late final CliSession session;

  /// Types [line] and returns what it printed straight away.
  String run(String line) {
    _out.clear();
    session.execute(line);
    return drain();
  }

  /// Runs each line and returns everything printed.
  String runAll(List<String> lines) => lines.map(run).join();

  /// Output printed since the last call, e.g. by a ping finishing.
  String drain() {
    final text = _out.toString();
    _out.clear();
    return text;
  }
}

/// Drives a PC command prompt.
class PcTerminal {
  PcTerminal(Pc pc) {
    shell = PcShell(pc, write: _out.write);
  }

  final _out = StringBuffer();
  late final PcShell shell;

  String run(String line) {
    _out.clear();
    shell.execute(line);
    return drain();
  }

  String drain() {
    final text = _out.toString();
    _out.clear();
    return text;
  }
}
