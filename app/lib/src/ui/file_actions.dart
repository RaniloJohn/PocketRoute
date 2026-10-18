import 'package:flutter/material.dart';
import 'package:pocketroute_core/pocketroute_core.dart';
import 'package:share_plus/share_plus.dart';

import '../lab/lab_controller.dart';
import '../lab/lab_store.dart';
import '../theme.dart';

const _dialogShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(Tokens.radius)),
);

/// Opening, saving and sharing labs. [replace] swaps the open lab.
class FileActions {
  FileActions({
    required this.context,
    required this.lab,
    required this.replace,
    LabStore? store,
  }) : store = store ?? LabStore();

  final BuildContext context;
  final LabController lab;
  final void Function(LabController next, {bool showNotes}) replace;
  final LabStore store;

  Future<void> openStarter(StarterLab starter) async {
    try {
      replace(
        LabController(lab: await store.loadStarter(starter)),
        showNotes: true,
      );
    } on Object catch (e) {
      _fail('Could not open ${starter.title}', e);
    }
  }

  Future<void> open() async {
    final labs = await store.list();
    if (!context.mounted) return;
    final chosen = await showDialog<SavedLab>(
      context: context,
      builder: (context) => _OpenDialog(labs: labs, store: store),
    );
    if (chosen == null) return;
    final warnings = <String>[];
    try {
      final opened = await store.load(chosen.file, warnings: warnings);
      replace(LabController(lab: opened, savedPath: chosen.file.path));
      if (warnings.isNotEmpty && context.mounted) {
        await _message(
          'Opened with problems',
          'Some parts of this lab could not be loaded:\n\n'
              '${warnings.map((w) => '• $w').join('\n')}',
        );
      }
    } on LabFormatException catch (e) {
      _fail('Could not open ${chosen.name}', e.message);
    } on Object catch (e) {
      _fail('Could not open ${chosen.name}', e);
    }
  }

  /// Saves under the current name, asking for one the first time.
  Future<void> save({bool askName = false}) async {
    var name = lab.name;
    if (askName || lab.savedPath == null) {
      final entered = await _askName(lab.name);
      if (entered == null) return;
      name = entered;
    }
    try {
      lab.name = name;
      final file = await store.save(lab.toLab(), name);
      lab
        ..savedPath = file.path
        ..notify('Saved $name');
    } on Object catch (e) {
      _fail('Could not save', e);
    }
  }

  /// Saves, then hands the file to the Android share sheet.
  Future<void> share() async {
    try {
      final file = await store.save(lab.toLab(), lab.name);
      lab.savedPath = file.path;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/zip')],
          subject: '${lab.name} (PocketRoute lab)',
        ),
      );
    } on Object catch (e) {
      _fail('Could not share', e);
    }
  }

  Future<void> showNotes() => _message(
    lab.name,
    lab.notes.trim().isEmpty ? 'This lab has no notes.' : lab.notes,
    markdown: true,
  );

  Future<String?> _askName(String initial) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        shape: _dialogShape,
        title: const Text('Save lab', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  void _fail(String title, Object error) {
    if (context.mounted) _message(title, '$error');
  }

  Future<void> _message(String title, String body, {bool markdown = false}) =>
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          shape: _dialogShape,
          title: Text(title, style: const TextStyle(fontSize: 16)),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SingleChildScrollView(
              child: markdown
                  ? _Markdown(body)
                  : Text(body, style: const TextStyle(fontSize: 13)),
            ),
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

class _OpenDialog extends StatefulWidget {
  const _OpenDialog({required this.labs, required this.store});

  final List<SavedLab> labs;
  final LabStore store;

  @override
  State<_OpenDialog> createState() => _OpenDialogState();
}

class _OpenDialogState extends State<_OpenDialog> {
  late final labs = [...widget.labs];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: _dialogShape,
      title: const Text('Open lab', style: TextStyle(fontSize: 16)),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: SizedBox(
        width: 420,
        child: labs.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(20),
                child: Text(
                  'No saved labs yet. Use File › Save, or start from a '
                  'starter lab.',
                  style: TextStyle(fontSize: 13, color: Tokens.muted),
                ),
              )
            : ListView.separated(
                shrinkWrap: true,
                itemCount: labs.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, color: Tokens.border),
                itemBuilder: (context, i) {
                  final lab = labs[i];
                  return ListTile(
                    dense: true,
                    title: Text(
                      lab.name,
                      style: const TextStyle(fontSize: 13.5),
                    ),
                    subtitle: Text(
                      _when(lab.modified),
                      style: const TextStyle(fontSize: 12),
                    ),
                    onTap: () => Navigator.pop(context, lab),
                    trailing: IconButton(
                      tooltip: 'Delete',
                      icon: const Icon(Icons.delete_outline, size: 20),
                      onPressed: () async {
                        await lab.file.delete();
                        setState(() => labs.removeAt(i));
                      },
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  static String _when(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }
}

/// Just enough Markdown for lab notes: `#` headings, `-` and numbered
/// lists, **bold** and `code`.
class _Markdown extends StatelessWidget {
  const _Markdown(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    // Lines wrapped in the source join up so the text reflows to the
    // dialog width: (list marker or null, text) per paragraph or item.
    final items = <(String?, String)>[];
    var open = false;
    final listItem = RegExp(r'^(- |\d+\. )');
    for (final raw in text.split('\n')) {
      final line = raw.trimRight();
      final match = listItem.firstMatch(line);
      if (line.isEmpty) {
        items.add((null, ''));
        open = false;
      } else if (line.startsWith('# ')) {
        // The dialog title already shows the lab name.
        open = false;
      } else if (match != null) {
        final marker = match[0]!.startsWith('-') ? '•' : match[0]!.trim();
        items.add((marker, line.substring(match.end)));
        open = true;
      } else if (open) {
        final (marker, before) = items.removeLast();
        items.add((marker, '$before ${line.trim()}'));
      } else {
        items.add((null, line));
        open = true;
      }
    }
    final blocks = <Widget>[
      for (final (marker, body) in items)
        if (marker == null && body.isEmpty)
          const SizedBox(height: 8)
        else if (marker == null)
          _inline(body)
        else
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 20, child: Text(marker, style: _body)),
                Expanded(child: _inline(body)),
              ],
            ),
          ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: blocks,
    );
  }

  static const _body = TextStyle(
    fontSize: 13.5,
    height: 1.45,
    color: Tokens.ink,
  );

  Widget _inline(String line) {
    final spans = <InlineSpan>[];
    final pattern = RegExp(r'\*\*(.+?)\*\*|`(.+?)`');
    var at = 0;
    for (final m in pattern.allMatches(line)) {
      spans.add(TextSpan(text: line.substring(at, m.start)));
      if (m[1] != null) {
        spans.add(
          TextSpan(
            text: m[1],
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: m[2],
            style: const TextStyle(
              fontFamily: Tokens.mono,
              fontSize: 12.5,
              backgroundColor: Color(0xFFEEF1F4),
            ),
          ),
        );
      }
      at = m.end;
    }
    spans.add(TextSpan(text: line.substring(at)));
    return Text.rich(TextSpan(style: _body, children: spans));
  }
}
