import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../lab/terminal.dart';
import '../theme.dart';

const _mono = TextStyle(
  fontFamily: Tokens.mono,
  fontSize: 12.5,
  height: 1.45,
  color: Tokens.terminalText,
);

/// Scrollback, an inline input line, and a key row for keys that touch
/// keyboards lack (Tab, ?, Ctrl+Z, history).
class TerminalView extends StatefulWidget {
  const TerminalView({super.key, required this.buffer});

  final TerminalBuffer buffer;

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  late final _focus = FocusNode(onKeyEvent: _onKey);
  int? _historyIndex;

  TerminalBuffer get _buffer => widget.buffer;

  @override
  void initState() {
    super.initState();
    _buffer.addListener(_scrollToEnd);
  }

  @override
  void didUpdateWidget(TerminalView old) {
    super.didUpdateWidget(old);
    if (old.buffer != widget.buffer) {
      old.buffer.removeListener(_scrollToEnd);
      widget.buffer.addListener(_scrollToEnd);
    }
  }

  @override
  void dispose() {
    _buffer.removeListener(_scrollToEnd);
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.minScrollExtent);
      }
    });
  }

  void _setInput(String text) {
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _submit() {
    // A command is still running (e.g. ping): keep the typed text for later.
    if (_buffer.backend.busy) {
      _focus.requestFocus();
      return;
    }
    final line = _input.text;
    _historyIndex = null;
    _setInput('');
    _buffer.submit(line);
    _focus.requestFocus();
  }

  void _help() {
    _buffer.help(_input.text);
    _focus.requestFocus();
  }

  void _complete() {
    final completed = _buffer.backend.complete(_input.text);
    if (completed != null) _setInput(completed);
    _focus.requestFocus();
  }

  void _historyStep(int delta) {
    final history = _buffer.history;
    if (history.isEmpty) return;
    var index = (_historyIndex ?? history.length) + delta;
    if (index >= history.length) {
      _historyIndex = null;
      _setInput('');
      return;
    }
    index = index.clamp(0, history.length - 1);
    _historyIndex = index;
    _setInput(history[index]);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.tab) {
      _complete();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _historyStep(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _historyStep(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyZ &&
        HardwareKeyboard.instance.isControlPressed) {
      _buffer.ctrlZ();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onChanged(String text) {
    // '?' shows help at once, as on a real console, and is never kept.
    if (text.endsWith('?')) {
      _setInput(text.substring(0, text.length - 1));
      _help();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: _focus.requestFocus,
            child: Container(
              color: Tokens.terminal,
              child: ListenableBuilder(
                listenable: _buffer,
                builder: (context, _) {
                  final lines = _buffer.lines;
                  final busy = _buffer.backend.busy;
                  // The input row stays at a fixed place in the tree (not in
                  // the list) so it keeps keyboard focus as output arrives.
                  return Column(
                    children: [
                      Expanded(
                        // Reversed, so the newest line stays pinned to the
                        // bottom whatever the height does.
                        child: ListView.builder(
                          controller: _scroll,
                          reverse: true,
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                          itemCount: lines.length + (busy ? 1 : 0),
                          itemBuilder: (context, i) {
                            final index = lines.length - 1 - i + (busy ? 1 : 0);
                            return Text(
                              index < lines.length
                                  ? lines[index]
                                  : _buffer.partial,
                              style: _mono,
                            );
                          },
                        ),
                      ),
                      Offstage(
                        offstage: busy,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                          child: _inputLine(),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
        _keyRow(),
      ],
    );
  }

  Widget _inputLine() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          '${_buffer.partial}${_buffer.backend.prompt}',
          style: _mono.copyWith(color: Tokens.terminalPrompt),
        ),
        Expanded(
          child: TextField(
            controller: _input,
            focusNode: _focus,
            autofocus: true,
            style: _mono,
            cursorColor: Tokens.terminalText,
            cursorWidth: 7,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
            textInputAction: TextInputAction.send,
            decoration: const InputDecoration.collapsed(hintText: ''),
            onChanged: _onChanged,
            onSubmitted: (_) => _submit(),
          ),
        ),
      ],
    );
  }

  Widget _keyRow() {
    Widget key(
      String label,
      VoidCallback onTap, {
      double flex = 1,
      String? tip,
    }) {
      final button = SizedBox(
        height: 32,
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.zero,
            backgroundColor: Colors.white,
            foregroundColor: Tokens.ink,
            side: const BorderSide(color: Tokens.control),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(3)),
            ),
            textStyle: const TextStyle(fontFamily: Tokens.mono, fontSize: 12),
          ),
          child: Text(label),
        ),
      );
      return Expanded(
        flex: (flex * 10).round(),
        child: tip == null ? button : Tooltip(message: tip, child: button),
      );
    }

    return Container(
      padding: const EdgeInsets.all(6),
      decoration: const BoxDecoration(
        color: Tokens.chromeAlt,
        border: Border(top: BorderSide(color: Tokens.border)),
      ),
      child: Row(
        spacing: 4,
        children: [
          key('Tab', _complete, tip: 'Complete the word'),
          key('?', _help, tip: 'Show what can come next'),
          key(
            'Ctrl+Z',
            () {
              _buffer.ctrlZ();
              _focus.requestFocus();
            },
            flex: 1.4,
            tip: 'Leave configuration mode',
          ),
          key('↑', () => _historyStep(-1), tip: 'Previous command'),
          key('↓', () => _historyStep(1), tip: 'Next command'),
          key('Enter', _submit, flex: 1.3),
        ],
      ),
    );
  }
}
