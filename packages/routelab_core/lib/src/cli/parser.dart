import 'command.dart';

/// The result of walking a command tree over some words.
sealed class Walk {
  const Walk();
}

/// Every word matched. [node] is null when there were no words.
final class WalkOk extends Walk {
  const WalkOk(this.node, this.options, this.args, {required this.negated});

  final CmdNode? node;

  /// What may come next.
  final List<CmdNode> options;
  final Map<String, Object> args;
  final bool negated;

  CommandHandler? get handler => node?.handler(negated: negated);
}

/// Word [wordIndex] matched nothing.
final class WalkInvalid extends Walk {
  const WalkInvalid(this.wordIndex);

  final int wordIndex;
}

/// Word [wordIndex] is a prefix of more than one keyword.
final class WalkAmbiguous extends Walk {
  const WalkAmbiguous(this.wordIndex);

  final int wordIndex;
}

/// Walks [roots] over every word of [input].
///
/// Per word: an exact keyword wins; otherwise a unique keyword prefix; several
/// keyword prefixes are ambiguous; otherwise the first argument that matches.
Walk walk(List<CmdNode> roots, CommandInput input) {
  var options = roots;
  CmdNode? node;
  final args = <String, Object>{};
  var negated = false;
  var i = 0;
  while (i < input.words.length) {
    final lower = input.words[i].text.toLowerCase();
    CmdNode? picked;
    var consumed = 1;
    Object? value;

    final prefixed = <CmdNode>[];
    for (final option in options) {
      if (option.token case Keyword(:final word)) {
        if (word == lower) {
          picked = option;
          break;
        }
        if (word.startsWith(lower)) prefixed.add(option);
      }
    }
    if (picked == null && prefixed.length > 1) return WalkAmbiguous(i);
    picked ??= prefixed.isEmpty ? null : prefixed.single;
    if (picked == null) {
      for (final option in options) {
        if (option.token case final ArgToken arg) {
          final match = arg.match(input, i);
          if (match != null) {
            picked = option;
            consumed = match.consumed;
            value = match.value;
            break;
          }
        }
      }
    }
    if (picked == null) return WalkInvalid(i);

    if (picked.isNegation) negated = true;
    if (picked.token case ArgToken(:final name)) args[name] = value!;
    node = picked;
    options = picked.children;
    i += consumed;
  }
  return WalkOk(node, options, args, negated: negated);
}
