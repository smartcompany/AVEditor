import 'dart:math' as math;

import 'package:aveditor/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Circular convert progress: clockwise ring fill with percent in the center.
///
/// Pass [progress] as `null` for an indeterminate spinning ring (before the
/// first progress callback).
class ConvertProgressView extends StatelessWidget {
  const ConvertProgressView({
    super.key,
    required this.label,
    required this.progress,
  });

  final String label;

  /// `0..1` while converting, or `null` before progress is known.
  final double? progress;

  static const _size = 148.0;
  static const _stroke = 10.0;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            textAlign: TextAlign.center,
            style: GoogleFonts.dmSans(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppTheme.ink,
            ),
          ),
          const SizedBox(height: 28),
          SizedBox(
            width: _size,
            height: _size,
            child: progress == null
                ? const _IndeterminateRing(
                    size: _size,
                    strokeWidth: _stroke,
                  )
                : _DeterminateRing(
                    progress: progress!.clamp(0.0, 1.0),
                    strokeWidth: _stroke,
                  ),
          ),
        ],
      ),
    );
  }
}

class _DeterminateRing extends StatelessWidget {
  const _DeterminateRing({
    required this.progress,
    required this.strokeWidth,
  });

  final double progress;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: progress),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      builder: (context, animated, _) {
        final percent = (animated * 100).round();
        return CustomPaint(
          painter: _ConvertRingPainter(
            progress: animated,
            strokeWidth: strokeWidth,
          ),
          child: Center(
            child: Text(
              '$percent%',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 32,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
                color: AppTheme.ink,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _IndeterminateRing extends StatefulWidget {
  const _IndeterminateRing({
    required this.size,
    required this.strokeWidth,
  });

  final double size;
  final double strokeWidth;

  @override
  State<_IndeterminateRing> createState() => _IndeterminateRingState();
}

class _IndeterminateRingState extends State<_IndeterminateRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _spin,
      builder: (context, _) {
        return CustomPaint(
          painter: _ConvertRingPainter(
            progress: 0.22,
            strokeWidth: widget.strokeWidth,
            startAngle: _spin.value * 2 * math.pi - math.pi / 2,
          ),
          child: Center(
            child: Text(
              '…',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: AppTheme.muted,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ConvertRingPainter extends CustomPainter {
  _ConvertRingPainter({
    required this.progress,
    required this.strokeWidth,
    this.startAngle = -math.pi / 2,
  });

  final double progress;
  final double strokeWidth;

  /// Arc start in radians. Default is 12 o'clock.
  final double startAngle;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) - strokeWidth) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = const Color(0x33FFFFFF);
    canvas.drawCircle(center, radius, track);

    if (progress <= 0) return;

    final sweep = 2 * math.pi * progress.clamp(0.0, 1.0);
    final shader = SweepGradient(
      startAngle: 0,
      endAngle: 2 * math.pi,
      colors: const [
        AppTheme.gradientOrange,
        AppTheme.gradientMagenta,
        AppTheme.gradientPurple,
        AppTheme.gradientCyan,
        AppTheme.gradientOrange,
      ],
      stops: const [0.0, 0.28, 0.55, 0.82, 1.0],
      transform: GradientRotation(startAngle),
    ).createShader(rect);

    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..shader = shader;

    canvas.drawArc(rect, startAngle, sweep, false, arc);
  }

  @override
  bool shouldRepaint(covariant _ConvertRingPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.startAngle != startAngle;
  }
}
