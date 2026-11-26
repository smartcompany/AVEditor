import 'package:aveditor/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class EditorOnboardingStep {
  const EditorOnboardingStep({
    this.targetKey,
    this.resolveHole,
    this.onEnter,
    required this.title,
    required this.body,
  }) : assert(targetKey != null || resolveHole != null);

  final GlobalKey? targetKey;

  /// Hole in the overlay's local coordinates (for painted timeline chips, etc.).
  final Rect? Function(RenderBox overlayBox)? resolveHole;

  /// Called when this step becomes active (before measuring the hole).
  final VoidCallback? onEnter;

  final String title;
  final String body;
}

/// First-run coach marks. Dims the editor and spotlights one target at a time.
class EditorOnboardingOverlay extends StatefulWidget {
  const EditorOnboardingOverlay({
    super.key,
    required this.steps,
    required this.skipLabel,
    required this.nextLabel,
    required this.doneLabel,
    required this.onFinished,
  });

  final List<EditorOnboardingStep> steps;
  final String skipLabel;
  final String nextLabel;
  final String doneLabel;
  final VoidCallback onFinished;

  @override
  State<EditorOnboardingOverlay> createState() =>
      _EditorOnboardingOverlayState();
}

class _EditorOnboardingOverlayState extends State<EditorOnboardingOverlay>
    with SingleTickerProviderStateMixin {
  var _index = 0;
  Rect? _hole;
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _showStep(0));
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _showStep(int index) {
    if (!mounted || widget.steps.isEmpty) return;
    final clamped = index.clamp(0, widget.steps.length - 1);
    setState(() {
      _index = clamped;
      _hole = null;
    });
    widget.steps[clamped].onEnter?.call();
    // onEnter may switch tabs / layout — measure after the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _measure();
      // Second pass if the target wasn't laid out yet (studio rising, etc.).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _measure();
      });
    });
  }

  void _measure() {
    if (!mounted || widget.steps.isEmpty) return;
    final step = widget.steps[_index.clamp(0, widget.steps.length - 1)];
    final overlayBox = context.findRenderObject() as RenderBox?;
    if (overlayBox == null || !overlayBox.hasSize) {
      setState(() => _hole = null);
      return;
    }
    if (step.resolveHole != null) {
      setState(() => _hole = step.resolveHole!(overlayBox));
      return;
    }
    final key = step.targetKey;
    final box = key?.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      setState(() => _hole = null);
      return;
    }
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    setState(() => _hole = (topLeft & box.size).inflate(10));
  }

  void _go(int next) {
    if (next >= widget.steps.length) {
      widget.onFinished();
      return;
    }
    _showStep(next);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.steps.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onFinished());
      return const SizedBox.shrink();
    }

    final step = widget.steps[_index];
    final size = MediaQuery.sizeOf(context);
    final hole = _hole;
    final isLast = _index >= widget.steps.length - 1;
    final cardTop = _cardTop(size: size, hole: hole);

    return Material(
      color: Colors.transparent,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _pulse,
              builder: (context, _) {
                final glow = 0.35 + _pulse.value * 0.25;
                return CustomPaint(
                  painter: _SpotlightPainter(
                    hole: hole,
                    glowAlpha: glow,
                  ),
                );
              },
            ),
          ),
          // Block taps on the editor while coaching.
          const Positioned.fill(child: AbsorbPointer()),
          Positioned(
            left: 20,
            right: 20,
            top: cardTop,
            child: _CoachCard(
              stepIndex: _index,
              stepCount: widget.steps.length,
              title: step.title,
              body: step.body,
              skipLabel: widget.skipLabel,
              primaryLabel: isLast ? widget.doneLabel : widget.nextLabel,
              onSkip: widget.onFinished,
              onPrimary: () => _go(_index + 1),
            ),
          ),
        ],
      ),
    );
  }

  double _cardTop({required Size size, required Rect? hole}) {
    const cardGuess = 168.0;
    final safeTop = MediaQuery.paddingOf(context).top + 12;
    final safeBottom = size.height - MediaQuery.paddingOf(context).bottom - 12;
    if (hole == null) {
      return (size.height - cardGuess) * 0.42;
    }
    final below = hole.bottom + 16;
    if (below + cardGuess <= safeBottom) return below;
    final above = hole.top - cardGuess - 16;
    if (above >= safeTop) return above;
    return safeTop.clamp(safeTop, safeBottom - cardGuess);
  }
}

class _CoachCard extends StatelessWidget {
  const _CoachCard({
    required this.stepIndex,
    required this.stepCount,
    required this.title,
    required this.body,
    required this.skipLabel,
    required this.primaryLabel,
    required this.onSkip,
    required this.onPrimary,
  });

  final int stepIndex;
  final int stepCount;
  final String title;
  final String body;
  final String skipLabel;
  final String primaryLabel;
  final VoidCallback onSkip;
  final VoidCallback onPrimary;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.surfaceElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.accent.withValues(alpha: 0.35)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  '${stepIndex + 1}/$stepCount',
                  style: GoogleFonts.dmSans(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.accentCyan,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: onSkip,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: AppTheme.muted,
                  ),
                  child: Text(skipLabel),
                ),
              ],
            ),
            Text(
              title,
              style: GoogleFonts.spaceGrotesk(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppTheme.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              body,
              style: GoogleFonts.dmSans(
                fontSize: 14,
                height: 1.4,
                color: AppTheme.muted,
              ),
            ),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: onPrimary,
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.accent,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                ),
                child: Text(
                  primaryLabel,
                  style: GoogleFonts.dmSans(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SpotlightPainter extends CustomPainter {
  _SpotlightPainter({required this.hole, required this.glowAlpha});

  final Rect? hole;
  final double glowAlpha;

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = Colors.black.withValues(alpha: 0.72);
    final full = Path()..addRect(Offset.zero & size);
    if (hole == null) {
      canvas.drawPath(full, dim);
      return;
    }
    final rrect = RRect.fromRectAndRadius(hole!, const Radius.circular(14));
    final cut = Path()
      ..addPath(full, Offset.zero)
      ..addRRect(rrect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(cut, dim);
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = AppTheme.accent.withValues(alpha: glowAlpha),
    );
  }

  @override
  bool shouldRepaint(covariant _SpotlightPainter oldDelegate) {
    return oldDelegate.hole != hole || oldDelegate.glowAlpha != glowAlpha;
  }
}
