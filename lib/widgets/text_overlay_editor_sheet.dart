import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/widgets/video_preview.dart';
import 'package:flutter/material.dart';

Future<void> showTextOverlayEditorSheet({
  required BuildContext context,
  required TextOverlay overlay,
  required ValueChanged<TextOverlay> onSave,
  required VoidCallback onDelete,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return _TextOverlayEditorSheet(
        overlay: overlay,
        onSave: onSave,
        onDelete: onDelete,
      );
    },
  );
}

class _TextOverlayEditorSheet extends StatefulWidget {
  const _TextOverlayEditorSheet({
    required this.overlay,
    required this.onSave,
    required this.onDelete,
  });

  final TextOverlay overlay;
  final ValueChanged<TextOverlay> onSave;
  final VoidCallback onDelete;

  @override
  State<_TextOverlayEditorSheet> createState() => _TextOverlayEditorSheetState();
}

class _TextOverlayEditorSheetState extends State<_TextOverlayEditorSheet> {
  late final TextEditingController _textController;
  late double _fontSize;
  late Color _color;

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
    _textController = TextEditingController(text: widget.overlay.text);
    _fontSize = widget.overlay.fontSize;
    _color = widget.overlay.color;
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _save() {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      return;
    }
    widget.onSave(
      widget.overlay.copyWith(
        text: text,
        fontSize: _fontSize,
        color: _color,
      ),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.editText, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            controller: _textController,
            decoration: InputDecoration(hintText: l10n.textOverlayHint),
            maxLines: 2,
          ),
          const SizedBox(height: 16),
          Text(l10n.fontSize, style: Theme.of(context).textTheme.bodySmall),
          Slider(
            value: _fontSize.clamp(minOverlayFontSize, maxOverlayFontSize),
            min: minOverlayFontSize,
            max: maxOverlayFontSize,
            divisions: 24,
            label: _fontSize.round().toString(),
            onChanged: (v) => setState(() => _fontSize = v),
          ),
          Text(l10n.textColor, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            children: _colors.map((c) {
              final selected = c == _color;
              return GestureDetector(
                onTap: () => setState(() => _color = c),
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
          const SizedBox(height: 20),
          Row(
            children: [
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  widget.onDelete();
                },
                child: Text(l10n.deleteText),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(l10n.cancel),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _save,
                child: Text(l10n.save),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
