import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/text_overlay_style.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/widgets/overlay_text_layout.dart';
import 'package:aveditor/widgets/video_preview.dart';
import 'package:flutter/material.dart';

Future<void> showTextOverlayEditorSheet({
  required BuildContext context,
  required TextOverlay overlay,
  required ValueChanged<TextOverlay> onChanged,
  VoidCallback? onRevert,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.surface,
    barrierColor: Colors.transparent,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return _TextOverlayEditorSheet(
        overlay: overlay,
        onChanged: onChanged,
        onRevert: onRevert,
      );
    },
  );
}

class _TextOverlayEditorSheet extends StatefulWidget {
  const _TextOverlayEditorSheet({
    required this.overlay,
    required this.onChanged,
    this.onRevert,
  });

  final TextOverlay overlay;
  final ValueChanged<TextOverlay> onChanged;
  final VoidCallback? onRevert;

  @override
  State<_TextOverlayEditorSheet> createState() => _TextOverlayEditorSheetState();
}

class _TextOverlayEditorSheetState extends State<_TextOverlayEditorSheet> {
  late double _fontSize;
  late Color _color;
  late TextOverlayStyle _style;
  var _closed = false;

  static const _colors = [
    Colors.white,
    Colors.black,
    Color(0xFFFF4D4D),
    Color(0xFFFFD166),
    Color(0xFF06D6A0),
    Color(0xFF4CC9F0),
  ];

  @override
  void initState() {
    super.initState();
    _fontSize = widget.overlay.fontSize;
    _color = widget.overlay.color;
    _style = widget.overlay.style;
  }

  TextOverlay _draft() {
    final factor = _fontSize / widget.overlay.fontSize;
    return widget.overlay.copyWith(
      fontSize: _fontSize,
      boxWidth: widget.overlay.boxWidth * factor,
      boxHeight: widget.overlay.boxHeight * factor,
      color: _color,
      style: _style,
    );
  }

  void _emitLive() {
    widget.onChanged(_draft());
  }

  void _cycleStyle() {
    setState(() => _style = _style.next);
    _emitLive();
  }

  void _revertAndClose() {
    if (_closed) return;
    _closed = true;
    widget.onRevert?.call();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _closed = true;
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.editText,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  onPressed: _revertAndClose,
                  icon: const Icon(Icons.undo),
                  tooltip: l10n.undo,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(l10n.fontSize, style: Theme.of(context).textTheme.bodySmall),
            Slider(
              value: _fontSize.clamp(minOverlayFontSize, maxOverlayFontSize),
              min: minOverlayFontSize,
              max: maxOverlayFontSize,
              divisions: 36,
              label: _fontSize.round().toString(),
              onChanged: (v) {
                setState(() => _fontSize = v);
                _emitLive();
              },
            ),
            Row(
              children: [
                Text(l10n.textStyle, style: Theme.of(context).textTheme.bodySmall),
                const Spacer(),
                _StyleCycleButton(
                  style: _style,
                  color: _color,
                  tooltip: l10n.textStyleCycle,
                  onPressed: _cycleStyle,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(l10n.textColor, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              children: _colors.map((c) {
                final selected = c == _color;
                return GestureDetector(
                  onTap: () {
                    setState(() => _color = c);
                    _emitLive();
                  },
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? AppTheme.accent : Colors.white24,
                        width: selected ? 3 : 1,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class _StyleCycleButton extends StatelessWidget {
  const _StyleCycleButton({
    required this.style,
    required this.color,
    required this.tooltip,
    required this.onPressed,
  });

  final TextOverlayStyle style;
  final Color color;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final background = overlayStyleBackgroundColor(style: style, accent: color);
    final fill = overlayTextFillColor(style: style, accent: color);

    return Tooltip(
      message: tooltip,
      child: Material(
        color: background.a > 0 ? background : AppTheme.background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: style == TextOverlayStyle.outline ? color : Colors.white24,
            width: style == TextOverlayStyle.outline ? 2 : 1,
          ),
        ),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: Text(
                'A',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: fill,
                  shadows: style == TextOverlayStyle.plain
                      ? const [Shadow(blurRadius: 4, color: Color(0x8A000000))]
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
