import 'command.dart';
import 'parser.dart';

/// One console connection to a device: current mode, prompt, help, completion.
///
/// The terminal UI echoes `prompt + line` itself, then calls [execute]; all
/// output arrives through [write]. Commands such as ping finish later in
/// simulated time, and [busy] stays true until they do.
class CliSession {
  CliSession(this.commands, {required this._hostname, required this._write});

  final CommandSet commands;
  final String Function() _hostname;
  final void Function(String text) _write;

  CliMode mode = CliMode.userExec;

  /// What a sub-mode is configuring: an interface, a VLAN ID, ...
  Object? target;
  bool busy = false;

  /// True while a saved configuration is replayed; warnings are suppressed.
  bool loadingConfig = false;
  final history = <String>[];

  String get prompt {
    final host = _hostname();
    return switch (mode) {
      CliMode.userExec => '$host>',
      CliMode.privilegedExec => '$host#',
      CliMode.globalConfig => '$host(config)#',
      CliMode.interfaceConfig => '$host(config-if)#',
      CliMode.subinterfaceConfig => '$host(config-subif)#',
      CliMode.vlanConfig => '$host(config-vlan)#',
    };
  }

  bool get inConfig => mode.isConfig;

  void write(String text) => _write(text);

  void writeln([String line = '']) => _write('$line\n');

  /// Runs one line. A line ending in `?` prints help instead; the terminal
  /// should then put the text before the `?` back on the input line.
  void execute(String line) {
    if (line.trim().isNotEmpty) history.add(line);
    if (line.endsWith('?')) {
      _help(line.substring(0, line.length - 1));
      return;
    }
    final input = CommandInput(line);
    if (input.words.isEmpty || input.words.first.text.startsWith('!')) return;
    var walked = walk(commands.rootsFor(mode), input);
    // A global command typed in a sub-mode runs there and leaves the sub-mode.
    if (walked is WalkInvalid && mode.isSubConfig) {
      final global = walk(commands.rootsFor(CliMode.globalConfig), input);
      if (global case WalkOk(handler: _?)) {
        mode = CliMode.globalConfig;
        target = null;
        walked = global;
      }
    }
    switch (walked) {
      case WalkInvalid(:final wordIndex):
        _caret(input.words[wordIndex].start);
      case WalkAmbiguous():
        writeln('% Ambiguous command:  "${line.trim()}"');
      case final WalkOk ok:
        final handler = ok.handler;
        if (handler == null) {
          writeln('% Incomplete command.');
        } else {
          handler(CommandContext(this, ok.args, negated: ok.negated));
        }
    }
  }

  /// Ctrl+Z: leave configuration mode.
  void ctrlZ() {
    if (!inConfig) return;
    mode = CliMode.privilegedExec;
    target = null;
  }

  /// Completes the last word if it is unambiguous; null otherwise.
  String? complete(String line) {
    final input = CommandInput(line);
    if (input.words.isEmpty || line.endsWith(' ')) return null;
    final last = input.words.last;
    final before = line.substring(0, last.start);
    final ok = walk(commands.rootsFor(mode), CommandInput(before));
    if (ok is! WalkOk) return null;
    final lower = last.text.toLowerCase();
    final keywords = [
      for (final option in ok.options)
        if (option.token case Keyword(:final word) when word.startsWith(lower))
          word,
    ];
    if (keywords.length == 1) return '$before${keywords.single} ';
    if (keywords.isNotEmpty) return null;
    for (final option in ok.options) {
      if (option.token case final ArgToken arg) {
        final completed = arg.complete(last.text);
        if (completed != null) return '$before$completed';
      }
    }
    return null;
  }

  void _help(String before) {
    final roots = commands.rootsFor(mode);
    final input = CommandInput(before);
    final listChildren = before.isEmpty || before.endsWith(' ');
    final walked = listChildren
        ? walk(roots, input)
        : walk(
            roots,
            CommandInput(before.substring(0, input.words.last.start)),
          );
    switch (walked) {
      case WalkInvalid(:final wordIndex):
        _caret(input.words[wordIndex].start);
      case WalkAmbiguous():
        writeln('% Ambiguous command:  "${before.trim()}"');
      case final WalkOk ok when listChildren:
        _listOptions(ok);
      case final WalkOk ok:
        final lower = input.words.last.text.toLowerCase();
        final hits = <String>[
          for (final option in ok.options)
            if (option.token case Keyword(:final word)
                when word.startsWith(lower))
              word,
          for (final option in ok.options)
            if (option.token case final ArgToken arg)
              for (final (label, _) in arg.helpRows(option.help))
                if (label.toLowerCase().startsWith(lower)) label,
        ]..sort();
        writeln(hits.isEmpty ? '% Unrecognized command' : hits.join('  '));
    }
  }

  void _listOptions(WalkOk ok) {
    final keywordRows = <(String, String)>[];
    final argRows = <(String, String)>[];
    for (final option in ok.options) {
      switch (option.token) {
        case Keyword(:final word):
          keywordRows.add((word, option.help));
        case final ArgToken arg:
          argRows.addAll(arg.helpRows(option.help));
      }
    }
    keywordRows.sort((a, b) => a.$1.compareTo(b.$1));
    final rows = [
      ...argRows,
      ...keywordRows,
      if (ok.handler != null) ('<cr>', ''),
    ];
    if (rows.isEmpty) {
      writeln('% Unrecognized command');
      return;
    }
    final width = rows.map((r) => r.$1.length).reduce((a, b) => a > b ? a : b);
    for (final (label, help) in rows) {
      writeln('  ${label.padRight(width + 2)}$help'.trimRight());
    }
  }

  void _caret(int column) {
    writeln('${' ' * (prompt.length + column)}^');
    writeln("% Invalid input detected at '^' marker.");
  }
}
