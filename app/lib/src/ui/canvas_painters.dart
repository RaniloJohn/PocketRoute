import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pocketroute_core/pocketroute_core.dart';

import '../lab/lab_controller.dart';
import '../theme.dart';
import 'device_glyph.dart';

/// Grid, dots or nothing, behind everything.
class GridPainter extends CustomPainter {
  GridPainter(this.pattern, this.colors);

  final CanvasPattern pattern;
  final CanvasColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.background);
    switch (pattern) {
      case CanvasPattern.plain:
        return;
      case CanvasPattern.dots:
        final paint = Paint()..color = colors.major;
        for (var x = 0.0; x <= size.width; x += 20) {
          for (var y = 0.0; y <= size.height; y += 20) {
            canvas.drawCircle(Offset(x, y), 1.3, paint);
          }
        }
      case CanvasPattern.grid:
        final minor = Paint()
          ..color = colors.minor
          ..strokeWidth = 1;
        final major = Paint()
          ..color = colors.major
          ..strokeWidth = 1;
        for (var x = 0.0; x <= size.width; x += 20) {
          canvas.drawLine(
            Offset(x + 0.5, 0),
            Offset(x + 0.5, size.height),
            x % 100 == 0 ? major : minor,
          );
        }
        for (var y = 0.0; y <= size.height; y += 20) {
          canvas.drawLine(
            Offset(0, y + 0.5),
            Offset(size.width, y + 0.5),
            y % 100 == 0 ? major : minor,
          );
        }
    }
  }

  @override
  bool shouldRepaint(GridPainter old) =>
      old.pattern != pattern || old.colors.background != colors.background;
}

/// Geometry of one drawn cable.
class CableGeometry {
  CableGeometry(this.link, this.a, this.b);

  final Link link;
  final NodeView a;
  final NodeView b;

  Offset get dir {
    final d = b.position - a.position;
    final len = d.distance;
    return len == 0 ? const Offset(1, 0) : d / len;
  }

  /// Where the cable meets each device's outline.
  Offset get endA => a.position + dir * outlineReach(a.kind, dir.dx, dir.dy);
  Offset get endB => b.position - dir * outlineReach(b.kind, dir.dx, dir.dy);

  /// Distance from [p] to the visible part of the cable.
  double distanceTo(Offset p) {
    final s = endA, e = endB;
    final d = e - s;
    final len2 = d.dx * d.dx + d.dy * d.dy;
    if (len2 == 0) return (p - s).distance;
    final t = (((p - s).dx * d.dx + (p - s).dy * d.dy) / len2).clamp(0.0, 1.0);
    return (p - (s + d * t)).distance;
  }
}

List<CableGeometry> cableGeometry(LabController lab) => [
  for (final link in lab.network.links)
    if (lab.nodeFor(link.a.device) case final a?)
      if (lab.nodeFor(link.b.device) case final b?) CableGeometry(link, a, b),
];

/// Cables, centre to centre, drawn under the devices.
class CablePainter extends CustomPainter {
  CablePainter(this.lab) : super(repaint: Listenable.merge([lab, lab.ticks]));

  final LabController lab;

  @override
  void paint(Canvas canvas, Size size) {
    final colors = lab.colors;
    for (final g in cableGeometry(lab)) {
      final link = g.link;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = switch (link.cable) {
          CableType.serial => colors.serial,
          CableType.console => colors.console,
          _ => colors.cable,
        };
      final path = Path()..moveTo(g.a.position.dx, g.a.position.dy);
      if (link.cable == CableType.serial) {
        final u = g.dir, p = Offset(-u.dy, u.dx);
        final mid = (g.endA + g.endB) / 2;
        for (final point in [
          mid - u * 9,
          mid - u * 3 + p * 7,
          mid + u * 3 - p * 7,
          mid + u * 9,
        ]) {
          path.lineTo(point.dx, point.dy);
        }
      }
      path.lineTo(g.b.position.dx, g.b.position.dy);
      switch (link.cable) {
        case CableType.copperCross:
          _dashed(canvas, path, paint, const [7, 5]);
        case CableType.console:
          _dashed(canvas, path, paint, const [0.1, 5]);
        default:
          canvas.drawPath(path, paint);
      }
    }
    final start = lab.cableStart;
    if (start != null) {
      final node = lab.nodeFor(start.device);
      if (node != null) {
        canvas.drawCircle(
          node.position,
          34,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = Tokens.accent
            ..strokeWidth = 1.5,
        );
      }
    }
  }

  static void _dashed(Canvas canvas, Path path, Paint paint, List<double> d) {
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      var on = true;
      var i = 0;
      while (distance < metric.length) {
        final step = d[i % d.length];
        if (on) {
          canvas.drawPath(
            metric.extractPath(
              distance,
              math.min(distance + step, metric.length),
            ),
            paint,
          );
        }
        distance += step;
        on = !on;
        i++;
      }
    }
  }

  @override
  bool shouldRepaint(CablePainter old) => true;
}

/// Link lights, port labels and the selection box, drawn over the devices.
class OverlayPainter extends CustomPainter {
  OverlayPainter(this.lab) : super(repaint: Listenable.merge([lab, lab.ticks]));

  final LabController lab;

  @override
  void paint(Canvas canvas, Size size) {
    final colors = lab.colors;
    for (final g in cableGeometry(lab)) {
      final u = g.dir;
      for (final (port, at, sign) in [
        (g.link.a, g.endA, 1.0),
        (g.link.b, g.endB, -1.0),
      ]) {
        final light = _lightFor(port, g.link);
        if (light != null) {
          canvas.drawCircle(at + u * (3 * sign), 3.4, Paint()..color = light);
        }
        if (lab.showPortLabels) {
          final p = Offset(-u.dy, u.dx);
          _label(canvas, port.shortName, at + u * (20 * sign) + p * 10, colors);
        }
      }
    }
    final selected = lab.selected;
    if (selected != null) {
      // Around the icon and its name label.
      final p = selected.position;
      final rect = Rect.fromLTRB(p.dx - 40, p.dy - 34, p.dx + 40, p.dy + 50);
      CablePainter._dashed(
        canvas,
        Path()..addRect(rect),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Tokens.accent,
        const [4, 3],
      );
    }
  }

  Color? _lightFor(Port port, Link link) {
    if (link.cable == CableType.console) return null;
    if (!port.isUp) return Tokens.linkDown;
    final device = port.device;
    if (device is L2Switch && !device.stp.forwards(port)) {
      return Tokens.linkStarting;
    }
    return Tokens.linkUp;
  }

  void _label(Canvas canvas, String text, Offset center, CanvasColors colors) {
    TextPainter painter(Paint? stroke) => TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: Tokens.sans,
          fontSize: 10.5,
          height: 1.2,
          fontFeatures: const [ui.FontFeature.tabularFigures()],
          foreground: stroke,
          color: stroke == null ? colors.subLabel : null,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final halo = painter(
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeJoin = StrokeJoin.round
        ..color = colors.background,
    );
    final fill = painter(null);
    final origin = center - Offset(fill.width / 2, fill.height / 2);
    halo.paint(canvas, origin);
    fill.paint(canvas, origin);
  }

  @override
  bool shouldRepaint(OverlayPainter old) => true;
}
