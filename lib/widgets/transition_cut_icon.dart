import 'package:flutter/material.dart';

/// Timeline cut-marker glyph: Push arrow into a vertical frame (door / screen).
///
/// Chip proportions (tall/narrow). Toolbar uses [TransitionCutIcon] with a
/// bolder layout so the same mark reads at Material icon size.
void paintTransitionCutIcon(
  Canvas canvas,
  Rect chip, {
  required Color color,
  double strokeWidth = 1.8,
}) {
  final paint = Paint()
    ..color = color
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke
    ..strokeWidth = strokeWidth;

  final c = chip.center;
  final h = chip.height * 0.42;
  final frameW = chip.width * 0.22;
  final frameLeft = c.dx + chip.width * 0.02;
  final frame = RRect.fromRectAndRadius(
    Rect.fromCenter(
      center: Offset(frameLeft + frameW / 2, c.dy),
      width: frameW,
      height: h,
    ),
    const Radius.circular(1.2),
  );
  canvas.drawRRect(frame, paint);

  final arrowTipX = frame.left - 1.5;
  final arrowTailX = c.dx - chip.width * 0.28;
  final head = chip.width * 0.12;
  canvas.drawLine(Offset(arrowTailX, c.dy), Offset(arrowTipX, c.dy), paint);
  canvas.drawLine(
    Offset(arrowTipX - head, c.dy - head * 0.85),
    Offset(arrowTipX, c.dy),
    paint,
  );
  canvas.drawLine(
    Offset(arrowTipX - head, c.dy + head * 0.85),
    Offset(arrowTipX, c.dy),
    paint,
  );
}

/// Hard-cut vertical bar on empty cut markers.
void paintHardCutIcon(
  Canvas canvas,
  Rect chip, {
  required Color color,
  double strokeWidth = 2.4,
}) {
  final paint = Paint()
    ..color = color
    ..strokeCap = StrokeCap.round
    ..style = PaintingStyle.stroke
    ..strokeWidth = strokeWidth;
  final c = chip.center;
  canvas.drawLine(
    Offset(c.dx, chip.top + chip.height * 0.2),
    Offset(c.dx, chip.bottom - chip.height * 0.2),
    paint,
  );
}

/// Toolbar icon: same Push mark as the timeline chip, sized to fill a button.
class TransitionCutIcon extends StatelessWidget {
  const TransitionCutIcon({
    super.key,
    this.size = 24,
    this.color,
  });

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved =
        color ?? IconTheme.of(context).color ?? const Color(0xFF1F1F1F);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _ToolbarTransitionCutPainter(color: resolved),
      ),
    );
  }
}

/// Bolder, squarer layout so the glyph matches neighboring Material icons.
class _ToolbarTransitionCutPainter extends CustomPainter {
  _ToolbarTransitionCutPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = (size.width * 0.11).clamp(2.4, 3.2);
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;

    final pad = size.width * 0.08;
    final left = pad;
    final right = size.width - pad;
    final cy = size.height / 2;

    // Tall frame on the right (door / screen).
    final frameW = size.width * 0.28;
    final frameH = size.height * 0.72;
    final frame = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(right - frameW / 2, cy),
        width: frameW,
        height: frameH,
      ),
      Radius.circular(size.width * 0.06),
    );
    canvas.drawRRect(frame, paint);

    // Arrow body → into the frame.
    final tipX = frame.left - size.width * 0.04;
    final tailX = left + size.width * 0.02;
    final head = size.width * 0.18;
    canvas.drawLine(Offset(tailX, cy), Offset(tipX, cy), paint);
    canvas.drawLine(
      Offset(tipX - head, cy - head * 0.75),
      Offset(tipX, cy),
      paint,
    );
    canvas.drawLine(
      Offset(tipX - head, cy + head * 0.75),
      Offset(tipX, cy),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _ToolbarTransitionCutPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
