import 'package:flutter/material.dart';
import 'package:pocketroute_core/pocketroute_core.dart';

import '../lab/lab_controller.dart';
import '../theme.dart';

/// Colour of a frame kind, shared by the event list and the moving packets.
Color frameColor(FrameKind kind) => switch (kind) {
  FrameKind.arp => const Color(0xFF7C4DDB),
  FrameKind.icmp => Tokens.accent,
  FrameKind.stp => const Color(0xFF6B7480),
  FrameKind.other => const Color(0xFF0E7490),
};

/// Simulation controls and the list of frames sent so far.
class SimulationPanel extends StatefulWidget {
  const SimulationPanel({super.key, required this.lab, required this.height});

  final LabController lab;
  final double height;

  @override
  State<SimulationPanel> createState() => _SimulationPanelState();
}

class _SimulationPanelState extends State<SimulationPanel> {
  final _scroll = ScrollController();
  int _shown = 0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lab = widget.lab;
    final events = lab.simEvents;
    if (events.length != _shown) {
      _shown = events.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
    const head = TextStyle(fontSize: 11, color: Tokens.faint);
    const cell = TextStyle(fontSize: 12, color: Tokens.ink);

    Widget button(String label, VoidCallback onTap, {bool selected = false}) =>
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: OutlinedButton(
            onPressed: onTap,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(64, 30),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              backgroundColor: selected ? Tokens.selected : Colors.white,
              foregroundColor: selected ? Tokens.accentText : Tokens.ink,
              side: const BorderSide(color: Tokens.control),
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(Tokens.radius)),
              ),
              textStyle: const TextStyle(fontSize: 12.5),
            ),
            child: Text(label),
          ),
        );

    Widget row(List<Widget> cells) => Row(
      children: [
        SizedBox(width: 74, child: cells[0]),
        SizedBox(width: 150, child: cells[1]),
        SizedBox(width: 150, child: cells[2]),
        Expanded(child: cells[3]),
      ],
    );

    return Container(
      height: widget.height,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Tokens.windowBorder)),
      ),
      child: Column(
        children: [
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: const BoxDecoration(
              color: Tokens.chromeAlt,
              border: Border(bottom: BorderSide(color: Tokens.border)),
            ),
            child: Row(
              children: [
                const Text(
                  'Simulation',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 12),
                button('Step', lab.step),
                button(
                  lab.simPlaying ? 'Pause' : 'Play',
                  () => lab.setSimPlaying(!lab.simPlaying),
                  selected: lab.simPlaying,
                ),
                button('Clear', lab.clearEvents),
                const SizedBox(width: 6),
                SizedBox(
                  height: 24,
                  child: Checkbox(
                    value: lab.showStp,
                    onChanged: (v) => lab.setShowStp(v ?? false),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const Text('STP', style: TextStyle(fontSize: 12.5)),
                const Spacer(),
                Text('${events.length} frames', style: head),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
            child: row(const [
              Text('Time (ms)', style: head),
              Text('From', style: head),
              Text('To', style: head),
              Text('Frame', style: head),
            ]),
          ),
          Expanded(
            child: events.isEmpty
                ? const Center(
                    child: Text(
                      'Ping from a PC console, then press Step to follow '
                      'each frame.',
                      style: TextStyle(fontSize: 12.5, color: Tokens.muted),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemExtent: 22,
                    itemCount: events.length,
                    itemBuilder: (context, i) {
                      final e = events[i];
                      return row([
                        Text(
                          '${e.time}',
                          style: cell.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        Text(
                          e.from,
                          style: cell,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          e.to,
                          style: cell,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                color: frameColor(e.kind),
                                borderRadius: BorderRadius.circular(1.5),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                e.description,
                                style: cell,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ]);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
