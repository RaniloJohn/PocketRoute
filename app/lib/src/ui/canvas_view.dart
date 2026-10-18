import 'package:flutter/material.dart';
import 'package:pocketroute_core/pocketroute_core.dart';

import '../lab/lab_controller.dart';
import '../theme.dart';
import 'canvas_painters.dart';
import 'device_glyph.dart';

const sceneSize = Size(4000, 3000);

/// The topology: grid, cables and devices inside a pan/zoom viewer. Accepts
/// devices dragged from the palette.
class CanvasView extends StatelessWidget {
  const CanvasView({
    super.key,
    required this.lab,
    required this.transform,
    required this.onOpenConsole,
  });

  final LabController lab;
  final TransformationController transform;

  /// Opens a console; the offset is the device's position in this view.
  final void Function(NodeView node, Offset viewPosition) onOpenConsole;

  Offset _toView(Offset scene) =>
      MatrixUtils.transformPoint(transform.value, scene);

  @override
  Widget build(BuildContext context) {
    return DragTarget<DeviceKind>(
      onAcceptWithDetails: (details) {
        final box = context.findRenderObject()! as RenderBox;
        final local = box.globalToLocal(details.offset);
        lab.addDevice(details.data, transform.toScene(local));
      },
      builder: (context, candidates, rejected) => InteractiveViewer(
        transformationController: transform,
        constrained: false,
        minScale: 0.3,
        maxScale: 2.5,
        boundaryMargin: const EdgeInsets.all(400),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _onBackgroundTap(d.localPosition),
          child: SizedBox.fromSize(
            size: sceneSize,
            child: ListenableBuilder(
              listenable: lab,
              builder: (context, _) => Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: GridPainter(lab.pattern, lab.colors),
                    ),
                  ),
                  Positioned.fill(
                    child: CustomPaint(painter: CablePainter(lab)),
                  ),
                  for (final node in lab.nodes)
                    Positioned(
                      left: node.position.dx - 48,
                      top: node.position.dy - 28,
                      width: 96,
                      child: _DeviceWidget(
                        node: node,
                        lab: lab,
                        onTap: () => _onDeviceTap(context, node),
                        onOpen: () =>
                            onOpenConsole(node, _toView(node.position)),
                      ),
                    ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(painter: OverlayPainter(lab)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _onBackgroundTap(Offset scene) {
    switch (lab.tool) {
      case Tool.delete:
        CableGeometry? nearest;
        var best = 10.0;
        for (final g in cableGeometry(lab)) {
          final d = g.distanceTo(scene);
          if (d < best) {
            best = d;
            nearest = g;
          }
        }
        if (nearest != null) lab.removeLink(nearest.link);
      case Tool.cable:
        if (lab.cableStart != null) lab.cancelCable();
      case Tool.select || Tool.note:
        lab.select(null);
    }
  }

  Future<void> _onDeviceTap(BuildContext context, NodeView node) async {
    switch (lab.tool) {
      case Tool.select || Tool.note:
        lab.select(node);
      case Tool.delete:
        lab.removeDevice(node);
      case Tool.cable:
        if (lab.cable == CableChoice.auto) {
          final port = lab.firstUsablePort(node);
          if (port == null) {
            lab.message = '${node.name} has no free port for this cable';
            lab.select(lab.selected);
          } else {
            lab.pickCablePort(port);
          }
          return;
        }
        final port = await showDialog<Port>(
          context: context,
          builder: (_) => PortPicker(lab: lab, node: node),
        );
        if (port != null) lab.pickCablePort(port);
    }
  }
}

class _DeviceWidget extends StatelessWidget {
  const _DeviceWidget({
    required this.node,
    required this.lab,
    required this.onTap,
    required this.onOpen,
  });

  final NodeView node;
  final LabController lab;
  final VoidCallback onTap;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = lab.colors;
    final canMove = lab.tool == Tool.select;
    return GestureDetector(
      onTap: onTap,
      onDoubleTap: lab.tool == Tool.select ? onOpen : null,
      onPanStart: canMove ? (_) => lab.select(node) : null,
      onPanUpdate: canMove
          ? (d) => lab.moveDevice(node, node.position + d.delta)
          : null,
      onPanEnd: canMove
          ? (_) => lab.moveDevice(node, node.position, finished: true)
          : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DeviceGlyph(
            kind: node.kind,
            color: colors.icon,
            fill: colors.background,
          ),
          const SizedBox(height: 2),
          Text(
            node.name,
            maxLines: 1,
            overflow: TextOverflow.visible,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              height: 1.25,
              color: colors.label,
              shadows: colors.halo,
            ),
          ),
          if (_subLabel(node) case final sub?)
            Text(
              sub,
              maxLines: 1,
              style: TextStyle(
                fontSize: 11,
                height: 1.25,
                color: colors.subLabel,
                shadows: colors.halo,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
        ],
      ),
    );
  }

  /// A host's address, or nothing.
  static String? _subLabel(NodeView node) {
    final device = node.device;
    if (device is Pc) return device.ip.address?.toString();
    return null;
  }
}

/// Lists a device's ports for the cable tool; unusable ones are disabled.
class PortPicker extends StatelessWidget {
  const PortPicker({super.key, required this.lab, required this.node});

  final LabController lab;
  final NodeView node;

  @override
  Widget build(BuildContext context) {
    final ports = node.device.allPorts.toList();
    return Dialog(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(Tokens.radius)),
        side: BorderSide(color: Tokens.windowBorder),
      ),
      backgroundColor: Colors.white,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360, maxHeight: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Tokens.border)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${node.name}: choose a port',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${lab.cable.label} cable',
                    style: const TextStyle(fontSize: 12, color: Tokens.muted),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: ports.length,
                itemBuilder: (context, i) {
                  final port = ports[i];
                  final usable = lab.portUsable(port);
                  final peer = port.peer;
                  final note = peer != null
                      ? 'to ${lab.nodeFor(peer.device)?.name} ${peer.shortName}'
                      : usable
                      ? 'free'
                      : 'does not fit';
                  return InkWell(
                    onTap: usable ? () => Navigator.pop(context, port) : null,
                    child: Container(
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              port.name,
                              style: TextStyle(
                                fontSize: 13,
                                color: usable ? Tokens.ink : Tokens.faint,
                              ),
                            ),
                          ),
                          Text(
                            note,
                            style: TextStyle(
                              fontSize: 12,
                              color: usable ? Tokens.muted : Tokens.faint,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
