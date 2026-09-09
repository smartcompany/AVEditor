import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/text_overlay_style.dart';
import 'package:aveditor/models/text_template_pack.dart';
import 'package:aveditor/services/text_template_pack_service.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/widgets/overlay_fonts.dart';
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
  String? _templateId;
  String? _packItemId;
  String? _fontFamily;
  String? _animationId;
  int? _animationDurationMs;
  var _closed = false;

  final _packService = TextTemplatePackService.instance;

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
    _templateId = widget.overlay.templateId;
    _packItemId = widget.overlay.packItemId;
    _fontFamily = widget.overlay.fontFamily;
    _animationId = widget.overlay.animationId;
    _animationDurationMs = widget.overlay.animationDurationMs;
    _packService.addListener(_onPackService);
    _packService.ensureInitialized();
  }

  @override
  void dispose() {
    _packService.removeListener(_onPackService);
    super.dispose();
  }

  void _onPackService() {
    if (mounted) setState(() {});
  }

  TextOverlay _draft() {
    final fitted = measureFittedOverlayBox(
      text: widget.overlay.text,
      fontSize: _fontSize,
    );
    return widget.overlay.copyWith(
      fontSize: _fontSize,
      boxWidth: fitted.width,
      boxHeight: fitted.height,
      color: _color,
      style: _style,
      templateId: _templateId,
      packItemId: _packItemId,
      fontFamily: _fontFamily,
      animationId: _animationId,
      animationDurationMs: _animationDurationMs,
    );
  }

  void _emitLive() {
    widget.onChanged(_draft());
  }

  void _cycleStyle() {
    setState(() {
      _templateId = null;
      _packItemId = null;
      _style = _style.next;
    });
    _emitLive();
  }

  void _selectPack(TextTemplatePackItem item) {
    setState(() {
      _packItemId = item.id;
      _templateId = null;
      _style = TextOverlayStyle.plain;
      _fontFamily = item.style.preferredFontId ?? _fontFamily;
      _animationId = null;
      _animationDurationMs = null;
    });
    final fontId = item.style.preferredFontId;
    if (fontId != null) {
      OverlayFonts.ensureLoaded(fontId);
    }
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
                Text(
                  l10n.textStyle,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Spacer(),
                _StyleCycleButton(
                  style: _templateId == null && _packItemId == null
                      ? _style
                      : TextOverlayStyle.plain,
                  color: _color,
                  tooltip: l10n.textStyleCycle,
                  onPressed: _cycleStyle,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              l10n.textTemplates,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 72,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _packService.catalog.allItems.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final pack = _packService.catalog.allItems[index];
                  final selected = pack.id == _packItemId;
                  return _PackChip(
                    pack: pack,
                    accent: _color,
                    selected: selected,
                    onTap: () => _selectPack(pack),
                  );
                },
              ),
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

class _PackChip extends StatelessWidget {
  const _PackChip({
    required this.pack,
    required this.accent,
    required this.selected,
    required this.onTap,
  });

  final TextTemplatePackItem pack;
  final Color accent;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: selected ? AppTheme.accent : Colors.white24,
          width: selected ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 78,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 56,
                height: 28,
                child: Center(
                  child: OverlayTextDisplay(
                    text: 'Aa',
                    color: accent,
                    fontSize: 16,
                    maxWidth: 56,
                    fontFamily: pack.style.preferredFontId,
                    template: pack.style,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                pack.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Colors.white70,
                  fontSize: 10,
                ),
              ),
            ],
          ),
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
