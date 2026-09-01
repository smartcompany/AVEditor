import 'package:flutter/material.dart';

/// CapCut-style split mark: inward brackets with a center cut line (][|][).
class SplitClipIcon extends StatelessWidget {
  const SplitClipIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color ?? Colors.white;
    final size = IconTheme.of(context).size ?? 24;

    return CustomPaint(
      size: Size.square(size),
      painter: _SplitBracketPainter(color: color),
    );
  }
}

class _SplitBracketPainter extends CustomPainter {
  const _SplitBracketPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.095;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final barHeight = size.height * 0.62;
    final centerY = size.height / 2;
    final top = centerY - barHeight / 2;
    final bottom = centerY + barHeight / 2;
    final centerX = size.width / 2;
    final gap = size.width * 0.14;
    final arm = size.width * 0.22;

    final leftInner = centerX - gap / 2;
    final rightInner = centerX + gap / 2;

    final leftBracket = Path()
      ..moveTo(leftInner, top)
      ..lineTo(leftInner - arm, top)
      ..lineTo(leftInner - arm, bottom)
      ..lineTo(leftInner, bottom);

    final rightBracket = Path()
      ..moveTo(rightInner, top)
      ..lineTo(rightInner + arm, top)
      ..lineTo(rightInner + arm, bottom)
      ..lineTo(rightInner, bottom);

    canvas.drawPath(leftBracket, paint);
    canvas.drawPath(rightBracket, paint);

    canvas.drawLine(
      Offset(centerX, top + stroke * 0.4),
      Offset(centerX, bottom - stroke * 0.4),
      Paint()
        ..color = color
        ..strokeWidth = stroke * 0.85
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _SplitBracketPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
