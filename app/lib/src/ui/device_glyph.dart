import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../lab/lab_controller.dart';

/// A device icon with a solid backing in [fill], so cables drawn beneath it
/// disappear into the device instead of showing through the outline.
class DeviceGlyph extends StatelessWidget {
  const DeviceGlyph({
    super.key,
    required this.kind,
    required this.color,
    required this.fill,
    this.size = 56,
  });

  final DeviceKind kind;
  final Color color;
  final Color fill;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(painter: _BackingPainter(kind, fill)),
          SvgPicture.asset(
            'assets/devices/${kind.asset}.svg',
            colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
          ),
        ],
      ),
    );
  }
}

/// The filled silhouette of each icon, in the icons' 64-unit grid.
class _BackingPainter extends CustomPainter {
  _BackingPainter(this.kind, this.fill);

  final DeviceKind kind;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 64);
    final paint = Paint()..color = fill;
    RRect r(double x, double y, double w, double h, double radius) =>
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, w, h),
          Radius.circular(radius),
        );
    switch (kind) {
      case DeviceKind.router:
        canvas.drawCircle(const Offset(32, 32), 23, paint);
      case DeviceKind.l2switch:
        canvas.drawRRect(r(9, 11, 46, 42, 7), paint);
      case DeviceKind.l3switch:
        canvas.drawRRect(r(9, 9, 46, 46, 7), paint);
      case DeviceKind.pc:
        canvas.drawRRect(r(9.5, 12.5, 45, 31.5, 2.5), paint);
      case DeviceKind.laptop:
        canvas
          ..drawRRect(r(13, 13, 38, 26, 2.5), paint)
          ..drawRRect(r(6, 41.5, 52, 10, 2), paint);
      case DeviceKind.server:
        canvas.drawRRect(r(8, 12, 48, 40, 3), paint);
    }
  }

  @override
  bool shouldRepaint(_BackingPainter old) =>
      old.kind != kind || old.fill != fill;
}

/// How far a device's outline is from its centre along direction ([ux],
/// [uy]), for a 56 px icon. Cables end and link lights sit there.
double outlineReach(DeviceKind kind, double ux, double uy) {
  const scale = 56 / 64;
  if (kind == DeviceKind.router) return 24.5 * scale;
  final (hx, hy) = switch (kind) {
    DeviceKind.l2switch => (24.8, 22.8),
    DeviceKind.l3switch => (24.8, 24.8),
    DeviceKind.pc => (24.3, 21.0),
    DeviceKind.laptop => (26.0, 19.5),
    DeviceKind.server => (24.0, 20.0),
    DeviceKind.router => (0.0, 0.0),
  };
  final tx = ux.abs() < 1e-6 ? double.infinity : hx / ux.abs();
  final ty = uy.abs() < 1e-6 ? double.infinity : hy / uy.abs();
  return math.min(tx, ty) * scale;
}
