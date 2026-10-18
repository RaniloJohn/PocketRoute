import '../net/ipv4.dart';
import '../protocols/vlan.dart';
import 'session.dart';

typedef CommandHandler = void Function(CommandContext ctx);

/// One whitespace-separated word of input and where it starts in the line.
class Word {
  const Word(this.text, this.start);

  final String text;
  final int start;
}

/// A line split into words, keeping the raw text for rest-of-line arguments.
class CommandInput {
  CommandInput(this.raw)
    : words = [
        for (final m in RegExp(r'\S+').allMatches(raw)) Word(m[0]!, m.start),
      ];

  final String raw;
  final List<Word> words;
}

/// What a node in the command tree matches.
sealed class Token {
  const Token();
}

/// A fixed word, matched by any unique prefix (`conf` for `configure`).
final class Keyword extends Token {
  const Keyword(this.word);

  final String word;
}

/// A value the user types, stored in [CommandContext.args] under [name].
abstract class ArgToken extends Token {
  const ArgToken(this.name);

  final String name;

  /// Shown in `?` help, e.g. `WORD` or `A.B.C.D`.
  String get label;

  /// Matches input starting at word [index]; null if it does not fit.
  ArgMatch? match(CommandInput input, int index);

  /// `?` help rows for this argument.
  List<(String, String)> helpRows(String help) => [(label, help)];

  /// Tab completion for a partly typed word, or null.
  String? complete(String partial) => null;
}

class ArgMatch {
  const ArgMatch(this.consumed, this.value);

  /// Number of words used.
  final int consumed;
  final Object value;
}

/// Any single word.
final class WordArg extends ArgToken {
  const WordArg(super.name);

  @override
  String get label => 'WORD';

  @override
  ArgMatch? match(CommandInput input, int index) =>
      ArgMatch(1, input.words[index].text);
}

/// Everything to the end of the line, spacing preserved.
final class LineArg extends ArgToken {
  const LineArg(super.name);

  @override
  String get label => 'LINE';

  @override
  ArgMatch? match(CommandInput input, int index) => ArgMatch(
    input.words.length - index,
    input.raw.substring(input.words[index].start).trimRight(),
  );
}

/// An integer within [min]..[max].
final class IntArg extends ArgToken {
  const IntArg(super.name, this.min, this.max);

  final int min;
  final int max;

  @override
  String get label => '<$min-$max>';

  @override
  ArgMatch? match(CommandInput input, int index) {
    final value = int.tryParse(input.words[index].text);
    if (value == null || value < min || value > max) return null;
    return ArgMatch(1, value);
  }
}

/// A dotted-quad IPv4 address or mask.
final class Ipv4Arg extends ArgToken {
  const Ipv4Arg(super.name);

  @override
  String get label => 'A.B.C.D';

  @override
  ArgMatch? match(CommandInput input, int index) {
    final value = Ipv4Address.tryParse(input.words[index].text);
    return value == null ? null : ArgMatch(1, value);
  }
}

/// A VLAN list such as `10`, `10,20` or `10-20,30`.
final class VlanListArg extends ArgToken {
  const VlanListArg(super.name);

  @override
  String get label => 'WORD';

  @override
  ArgMatch? match(CommandInput input, int index) {
    final value = VlanSet.tryParse(input.words[index].text);
    return value == null ? null : ArgMatch(1, value);
  }
}

/// An interface type and number, as `Fa0/1`, `fastethernet 0/1` or `vlan 1`.
class InterfaceRef {
  const InterfaceRef(this.type, this.number);

  /// Canonical type name, e.g. `FastEthernet`.
  final String type;
  final String number;

  String get name => '$type$number';

  @override
  String toString() => name;
}

/// An interface type (by unique prefix) followed by its number.
final class InterfaceArg extends ArgToken {
  const InterfaceArg(super.name, this.types);

  /// Canonical type name -> help text.
  final Map<String, String> types;

  static final _typeAndNumber = RegExp(r'^([A-Za-z-]+)([0-9][0-9/.]*)?$');
  static final _number = RegExp(r'^[0-9][0-9/.]*$');

  @override
  String get label => 'interface';

  @override
  ArgMatch? match(CommandInput input, int index) {
    final m = _typeAndNumber.firstMatch(input.words[index].text);
    if (m == null) return null;
    final type = _resolveType(m[1]!);
    if (type == null) return null;
    final number = m[2];
    if (number != null) return ArgMatch(1, InterfaceRef(type, number));
    if (index + 1 < input.words.length &&
        _number.hasMatch(input.words[index + 1].text)) {
      return ArgMatch(2, InterfaceRef(type, input.words[index + 1].text));
    }
    return null;
  }

  @override
  List<(String, String)> helpRows(String help) => [
    for (final entry in types.entries) (entry.key, entry.value),
  ];

  @override
  String? complete(String partial) =>
      _number.hasMatch(partial) ? null : _resolveType(partial);

  String? _resolveType(String typed) {
    final lower = typed.toLowerCase();
    final hits = types.keys.where((t) => t.toLowerCase().startsWith(lower));
    return hits.length == 1 ? hits.single : null;
  }
}

/// A node in a mode's command tree.
class CmdNode {
  CmdNode(
    this.token,
    this.help, {
    this.children = const [],
    this.run,
    this.negate,
    this.isNegation = false,
  });

  CmdNode.keyword(
    String word,
    String help, {
    List<CmdNode> children = const [],
    CommandHandler? run,
    CommandHandler? negate,
  }) : this(Keyword(word), help, children: children, run: run, negate: negate);

  CmdNode.arg(
    ArgToken arg,
    String help, {
    List<CmdNode> children = const [],
    CommandHandler? run,
    CommandHandler? negate,
  }) : this(arg, help, children: children, run: run, negate: negate);

  final Token token;

  /// Our own wording, shown by `?`.
  final String help;
  final List<CmdNode> children;

  /// Runs when the command ends here.
  final CommandHandler? run;

  /// Runs when the command ends here and was prefixed with `no`.
  final CommandHandler? negate;

  /// True only for the synthetic `no` node.
  final bool isNegation;

  bool get hasNegatedForm =>
      negate != null || children.any((c) => c.hasNegatedForm);

  CommandHandler? handler({required bool negated}) => negated ? negate : run;
}

/// CLI modes, each with its own command tree and prompt.
enum CliMode {
  userExec,
  privilegedExec,
  globalConfig,
  interfaceConfig,
  subinterfaceConfig,
  vlanConfig;

  bool get isConfig => index >= globalConfig.index;

  /// Modes entered from global configuration (interface, VLAN, ...).
  bool get isSubConfig => index > globalConfig.index;
}

/// The command trees for every mode of one device.
class CommandSet {
  CommandSet(Map<CliMode, List<CmdNode>> roots)
    : _roots = {
        for (final MapEntry(key: mode, value: nodes) in roots.entries)
          mode: mode.isConfig ? [...nodes, _negationOf(nodes)] : nodes,
      };

  final Map<CliMode, List<CmdNode>> _roots;

  List<CmdNode> rootsFor(CliMode mode) => _roots[mode] ?? const [];

  static CmdNode _negationOf(List<CmdNode> nodes) => CmdNode(
    const Keyword('no'),
    'Undo a command or restore its default',
    children: nodes.where((n) => n.hasNegatedForm).toList(),
    isNegation: true,
  );
}

/// What a handler sees: parsed arguments and the session to act on.
class CommandContext {
  CommandContext(this.session, this.args, {required this.negated});

  final CliSession session;
  final Map<String, Object> args;
  final bool negated;

  T arg<T extends Object>(String name) => args[name] as T;

  T? optionalArg<T extends Object>(String name) => args[name] as T?;

  void write(String text) => session.write(text);

  void writeln([String line = '']) => session.write('$line\n');

  /// Advice for someone typing; not shown while a saved config is loading.
  void warn(String line) {
    if (!session.loadingConfig) writeln(line);
  }
}
