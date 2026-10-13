import 'package:aveditor/models/canvas_ratio.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:flutter/material.dart';

/// Ratio choices drawn over the top of the video. A tap applies immediately.
class CanvasRatioBar extends StatelessWidget {
  const CanvasRatioBar({
    super.key,
    required this.selected,
    required this.sourceAspect,
    required this.originalLabel,
    required this.onSelected,
    required this.onClose,
  });

  final CanvasRatio selected;
  final double sourceAspect;
  final String originalLabel;
  final ValueChanged<CanvasRatio> onSelected;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xE6121922),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 0, 6),
        child: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final ratio in CanvasRatio.values) ...[
                      _RatioChip(
                        ratio: ratio,
                        sourceAspect: sourceAspect,
                        label: ratio == CanvasRatio.original
                            ? originalLabel
                            : ratio.ratioLabel,
                        selected: ratio == selected,
                        onTap: () => onSelected(ratio),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              ),
            ),
            IconButton(
              onPressed: onClose,
              icon: const Icon(Icons.close),
              color: Colors.white,
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            ),
          ],
        ),
      ),
    );
  }
}

class _RatioChip extends StatelessWidget {
  const _RatioChip({
    required this.ratio,
    required this.sourceAspect,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final CanvasRatio ratio;
  final double sourceAspect;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const box = 36.0;
    final aspect = ratio.frameAspect(sourceAspect);
    final width = aspect >= 1 ? box : box * aspect;
    final height = aspect >= 1 ? box / aspect : box;
    final border = selected ? AppTheme.accent : AppTheme.muted;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 56,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: box,
              child: Center(
                child: Container(
                  width: width,
                  height: height,
                  decoration: BoxDecoration(
                    color: selected
                        ? AppTheme.accent.withValues(alpha: 0.25)
                        : Colors.white10,
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(color: border, width: selected ? 2 : 1),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: selected ? AppTheme.ink : AppTheme.muted,
                    fontSize: 11,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
