import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/models/text_entrance_animation.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/text_overlay_style.dart';
import 'package:aveditor/models/text_template_pack.dart';
import 'package:aveditor/services/text_template_pack_service.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/utils/editor_sheet_metrics.dart';
import 'package:aveditor/widgets/overlay_fonts.dart';
import 'package:aveditor/widgets/overlay_text_layout.dart';
import 'package:aveditor/widgets/text_entrance.dart';
import 'package:aveditor/widgets/text_template_pack_browser.dart';
import 'package:aveditor/widgets/video_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum TextStudioTab { templates, fonts, style, effects, animation, bubbles }

/// CapCut-style docked text studio: input bar + tabs + templates/style.
class TextStudioPanel extends StatefulWidget {
  const TextStudioPanel({
    super.key,
    required this.overlay,
    required this.textHint,
    required this.onChanged,
    required this.onTextChanged,
    required this.onConfirm,
    required this.maxSheetHeight,
    this.onFieldFocusChanged,
    this.onHeightChanged,
  });

  /// Input bar + tab bar — used by the editor to size the compose slot.
  static const composeChromeHeight = 120.0;

  /// Top grab strip (matches transition sheet feel).
  static const handleHeight = 28.0;

  final TextOverlay overlay;
  final String textHint;
  final ValueChanged<TextOverlay> onChanged;
  final ValueChanged<String> onTextChanged;
  final VoidCallback onConfirm;

  /// Max height available in the editor body (usually full body height).
  final double maxSheetHeight;

  final ValueChanged<bool>? onFieldFocusChanged;

  /// Compose slot / sheet height. [height] null restores the editor entry size.
  final void Function(double? height, {double bottom})? onHeightChanged;

  @override
  State<TextStudioPanel> createState() => _TextStudioPanelState();
}

class _TextStudioPanelState extends State<TextStudioPanel>
    with WidgetsBindingObserver {
  late final TextEditingController _textController;
  late final FocusNode _focusNode;
  TextStudioTab _tab = TextStudioTab.templates;
  var _inputExpanded = false;

  final _packService = TextTemplatePackService.instance;
  final _inputBarKey = GlobalKey();
  final _tabBarKey = GlobalKey();

  /// Rises with IME only — never falls (avoids riding the sheet down).
  var _pinnedKeyboard = 0.0;

  /// After IME dismiss: bottom-anchored tall sheet; re-focus keeps this.
  var _composeLockedTall = false;

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
    WidgetsBinding.instance.addObserver(this);
    _textController = TextEditingController(text: widget.overlay.text);
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChanged);
    _packService.addListener(_onPackService);
    _packService.ensureInitialized();
    // CapCut: open on Templates / Default with keyboard dismissed.
  }

  void _onFocusChanged() {
    if (!mounted) return;
    final focused = _focusNode.hasFocus;
    setState(() {
      if (!focused) _inputExpanded = false;
    });
    widget.onFieldFocusChanged?.call(focused);

    if (focused) {
      // Already compose-sized after a prior dismiss — don't reshuffle geometry
      // (that caused input to drop then rise). IME just covers the body.
      if (_composeLockedTall) return;
      _pinnedKeyboard = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) => _reportComposeSlot());
    } else {
      _lockTallComposeSlot();
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (_composeLockedTall || !_focusNode.hasFocus) return;
    _reportComposeSlot();
  }

  double _keyboardInset() {
    return MediaQueryData.fromView(View.of(context)).viewInsets.bottom;
  }

  double _renderHeight(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize) return box.size.height;
    return 0;
  }

  double _chromeHeight() {
    return TextStudioPanel.handleHeight +
        _renderHeight(_inputBarKey) +
        _renderHeight(_tabBarKey);
  }

  void _onHandleDragUpdate(DragUpdateDetails details) {
    // Don't fight the IME compose slot while the keyboard is rising.
    if (_focusNode.hasFocus && !_composeLockedTall) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final metrics = EditorSheetMetrics.of(context);
    final maxH = metrics.maxHeight.clamp(0.0, widget.maxSheetHeight);
    final minH = metrics.minHeight;
    final next = (box.size.height - details.delta.dy).clamp(minH, maxH);
    _composeLockedTall = false;
    _pinnedKeyboard = 0;
    widget.onHeightChanged?.call(next, bottom: 0);
  }

  void _onHandleDragEnd(DragEndDetails details) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final metrics = EditorSheetMetrics.of(context);
    final snapped = metrics.snapHeight(
      box.size.height,
      maxAvailable: widget.maxSheetHeight,
      velocity: details.primaryVelocity ?? 0,
    );
    if (snapped == null) {
      widget.onConfirm();
      return;
    }
    widget.onHeightChanged?.call(snapped, bottom: 0);
  }

  Widget _buildDragHandle() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: _onHandleDragUpdate,
      onVerticalDragEnd: _onHandleDragEnd,
      child: SizedBox(
        height: TextStudioPanel.handleHeight,
        child: Center(
          child: Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.28),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  /// Fill the keyboard gap; chrome Y stays fixed. Used on IME dismiss.
  void _lockTallComposeSlot() {
    if (!mounted || _composeLockedTall) return;
    final chrome = _chromeHeight();
    if (chrome <= 0 || _pinnedKeyboard <= 0) return;
    _composeLockedTall = true;
    widget.onHeightChanged?.call(chrome + _pinnedKeyboard, bottom: 0);
  }

  void _reportComposeSlot() {
    if (!mounted || !_focusNode.hasFocus || _composeLockedTall) return;
    final measured = _chromeHeight();
    // Keys may not be laid out on the first focus frame — never shrink to
    // handle-only or the sheet looks like it vanished.
    final chrome = measured >= TextStudioPanel.handleHeight + 80
        ? measured
        : TextStudioPanel.composeChromeHeight + TextStudioPanel.handleHeight;
    final keyboard = _keyboardInset();

    if (keyboard > _pinnedKeyboard) {
      _pinnedKeyboard = keyboard;
    }
    // Wait for a real IME inset — never park chrome at bottom:0 (bounce).
    if (_pinnedKeyboard <= 0) return;

    if (keyboard + 0.5 < _pinnedKeyboard) {
      _lockTallComposeSlot();
      return;
    }

    widget.onHeightChanged?.call(chrome, bottom: _pinnedKeyboard);
  }

  void _ensureKeyboardVisible() {
    void show() {
      if (!mounted || !_focusNode.hasFocus) return;
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      show();
      // iOS can drop the connection once when bottom inset changes; retry once.
      Future<void>.delayed(const Duration(milliseconds: 64), show);
    });
  }

  @override
  void didUpdateWidget(covariant TextStudioPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.overlay.id != widget.overlay.id) {
      _textController.text = widget.overlay.text;
      _focusNode.unfocus();
      _inputExpanded = false;
      _pinnedKeyboard = 0;
      _composeLockedTall = false;
    } else if (!_focusNode.hasFocus &&
        _textController.text != widget.overlay.text) {
      _textController.text = widget.overlay.text;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focusNode.removeListener(_onFocusChanged);
    _packService.removeListener(_onPackService);
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onPackService() {
    if (mounted) setState(() {});
  }

  void _emitOverlay(TextOverlay next) {
    widget.onChanged(fitOverlayBoxToText(next));
  }

  void _selectDefault() {
    _emitOverlay(
      widget.overlay.copyWith(
        style: TextOverlayStyle.plain,
        templateId: null,
        packItemId: null,
        animationId: '',
        animationDurationMs: null,
      ),
    );
  }

  Future<void> _selectPack(TextTemplatePackItem item) async {
    if (!_packService.isInstalled(item)) {
      try {
        await _packService.install(item);
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Download failed')));
        return;
      }
    }
    if (!mounted) return;
    final text = widget.overlay.text.trim().isEmpty
        ? item.title
        : widget.overlay.text;
    if (text != _textController.text) {
      _textController.text = text;
      widget.onTextChanged(text);
    }
    final fontId = item.style.preferredFontId;
    _emitOverlay(
      widget.overlay.copyWith(
        text: text,
        packItemId: item.id,
        templateId: null,
        style: TextOverlayStyle.plain,
        fontFamily: fontId ?? widget.overlay.fontFamily,
        // Clear override so the pack's catalog animation applies.
        animationId: null,
        animationDurationMs: null,
      ),
    );
    if (fontId != null) {
      OverlayFonts.ensureLoaded(fontId);
    }
  }

  void _cycleStyle() {
    _emitOverlay(
      widget.overlay.copyWith(
        style: widget.overlay.style.next,
        templateId: null,
        packItemId: null,
      ),
    );
  }

  bool get _isDefaultSelected =>
      widget.overlay.packItemId == null && widget.overlay.templateId == null;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final focused = _focusNode.hasFocus;

    // Fixed-height sheet from parent; focus only opens the keyboard.
    return Material(
      color: const Color(0xFF12141A),
      elevation: 8,
      shadowColor: Colors.black54,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildDragHandle(),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, inner) {
                    // Compose (focused): always keep the input visible above the
                    // keyboard. Browse: hide chrome only while collapsing away.
                    if (!focused && inner.maxHeight < 140) {
                      return const SizedBox.shrink();
                    }
                    if (focused) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          KeyedSubtree(
                            key: _inputBarKey,
                            child: _buildInputBar(l10n, focused: focused),
                          ),
                          if (inner.maxHeight >= 100)
                            KeyedSubtree(
                              key: _tabBarKey,
                              child: _buildTabBar(l10n),
                            ),
                        ],
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        KeyedSubtree(
                          key: _inputBarKey,
                          child: _buildInputBar(l10n, focused: focused),
                        ),
                        KeyedSubtree(
                          key: _tabBarKey,
                          child: _buildTabBar(l10n),
                        ),
                        Expanded(child: _buildTabBody(l10n)),
                      ],
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildInputBar(AppLocalizations l10n, {required bool focused}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('text_studio_field'),
              controller: _textController,
              focusNode: _focusNode,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              cursorColor: const Color(0xFF4CC9F0),
              // CapCut-like: less predictive bar / suggestion chrome above keyboard.
              autocorrect: false,
              enableSuggestions: false,
              smartDashesType: SmartDashesType.disabled,
              smartQuotesType: SmartQuotesType.disabled,
              // Multiline + newline so iOS shows the return key (not "done").
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              minLines: 1,
              maxLines: _inputExpanded ? 5 : 3,
              onChanged: widget.onTextChanged,
              onTap: () {
                // Ensure IME after a tap even if focus was already true.
                if (_focusNode.hasFocus) _ensureKeyboardVisible();
              },
              decoration: InputDecoration(
                hintText: widget.textHint,
                hintStyle: TextStyle(
                  color: Colors.white.withValues(alpha: 0.35),
                ),
                filled: true,
                fillColor: const Color(0xFF1C1F28),
                contentPadding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                suffixIconConstraints: const BoxConstraints(
                  minWidth: 40,
                  minHeight: 40,
                ),
                // Keep a stable suffix slot so focus doesn't remount the field.
                suffixIcon: IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 40,
                  ),
                  onPressed: focused
                      ? () {
                          setState(() => _inputExpanded = !_inputExpanded);
                        }
                      : null,
                  icon: Icon(
                    _inputExpanded
                        ? Icons.close_fullscreen
                        : Icons.open_in_full,
                    size: 20,
                    color: focused ? Colors.white70 : Colors.transparent,
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            width: 48,
            child: IconButton(
              onPressed: focused
                  ? () {
                      _focusNode.unfocus();
                      setState(() => _inputExpanded = false);
                    }
                  : widget.onConfirm,
              icon: Icon(
                focused ? Icons.keyboard_hide_outlined : Icons.check,
                color: focused ? Colors.white70 : const Color(0xFF4CC9F0),
              ),
              tooltip: focused ? null : l10n.save,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar(AppLocalizations l10n) {
    final labeled = <(TextStudioTab, String, bool)>[
      (TextStudioTab.templates, l10n.textStudioTabTemplates, true),
      (TextStudioTab.fonts, l10n.textStudioTabFonts, false),
      (TextStudioTab.style, l10n.textStudioTabStyle, true),
      (TextStudioTab.effects, l10n.textStudioTabEffects, false),
      (TextStudioTab.animation, l10n.textStudioTabAnimation, true),
      (TextStudioTab.bubbles, l10n.textStudioTabBubbles, false),
    ];

    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: labeled.length,
        separatorBuilder: (_, _) => const SizedBox(width: 4),
        itemBuilder: (context, index) {
          final (tab, label, enabled) = labeled[index];
          final selected = _tab == tab;
          return InkWell(
            onTap: enabled
                ? () => setState(() => _tab = tab)
                : () {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text(l10n.comingSoon)));
                  },
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.2,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: !enabled
                          ? Colors.white30
                          : selected
                          ? Colors.white
                          : Colors.white60,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Container(
                    height: 2,
                    width: 22,
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0xFF4CC9F0)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTabBody(AppLocalizations l10n) {
    switch (_tab) {
      case TextStudioTab.templates:
        return _buildTemplatesGrid(l10n);
      case TextStudioTab.style:
        return _buildStyleTab(l10n);
      case TextStudioTab.animation:
        return _buildAnimationTab(l10n);
      case TextStudioTab.fonts:
      case TextStudioTab.effects:
      case TextStudioTab.bubbles:
        return Center(
          child: Text(
            l10n.comingSoon,
            style: const TextStyle(color: Colors.white54),
          ),
        );
    }
  }

  Widget _buildTemplatesGrid(AppLocalizations l10n) {
    final packItems = <TextTemplatePackItem>[
      for (final category in _packService.catalog.categories) ...category.items,
    ];

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.85,
      ),
      itemCount: 1 + packItems.length,
      itemBuilder: (context, index) {
        if (index == 0) {
          return _TemplateTile(
            selected: _isDefaultSelected,
            label: l10n.textStudioDefault,
            onTap: _selectDefault,
            child: Text(
              'Aa',
              style: TextStyle(
                fontFamily: overlayFontFamily,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                shadows: const [
                  Shadow(blurRadius: 4, color: Color(0x8A000000)),
                ],
              ),
            ),
          );
        }
        final pack = packItems[index - 1];
        final selected = widget.overlay.packItemId == pack.id;
        final downloading = _packService.isDownloading(pack.id);
        final installed = _packService.isInstalled(pack);
        return _TemplateTile(
          selected: selected,
          label: pack.title,
          badge: pack.premium
              ? const Icon(Icons.diamond, size: 12, color: Color(0xFF4CC9F0))
              : downloading
              ? const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                )
              : !installed
              ? const Icon(Icons.download, size: 12, color: Colors.white54)
              : null,
          onTap: downloading ? null : () => _selectPack(pack),
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (pack.hasLottie && installed)
                PackLottieDecoration(
                  packItemId: pack.id,
                  width: 70,
                  height: 44,
                ),
              OverlayTextDisplay(
                text: 'Aa',
                color: widget.overlay.color,
                fontSize: 18,
                maxWidth: 64,
                fontFamily: pack.style.preferredFontId,
                template: pack.style,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAnimationTab(AppLocalizations l10n) {
    final resolved = resolveOverlayAnimation(widget.overlay);
    final options = <(String, String)>[
      ('', 'None'),
      (TextEntranceIds.typewriter, 'Typewriter'),
      (TextEntranceIds.fade, 'Fade'),
      (TextEntranceIds.slideUp, 'Slide up'),
    ];

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.85,
      ),
      itemCount: options.length,
      itemBuilder: (context, index) {
        final (id, label) = options[index];
        final selected = id.isEmpty
            ? resolved.isNone
            : resolved.id == id && !resolved.isNone;
        final previewEntrance = id.isEmpty
            ? TextEntranceState.fullyVisible
            : evaluateTextEntrance(
                animationId: id,
                text: 'Aa',
                progress: 0.65,
                fontSize: 18,
              );
        return _TemplateTile(
          selected: selected,
          label: label,
          onTap: () {
            _emitOverlay(
              widget.overlay.copyWith(
                animationId: id,
                animationDurationMs: id.isEmpty
                    ? null
                    : TextEntranceAnimation.defaultDurationMs,
              ),
            );
          },
          child: OverlayTextDisplay(
            text: 'Aa',
            color: widget.overlay.color,
            fontSize: 18,
            maxWidth: 64,
            template: resolveOverlayTemplate(widget.overlay),
            fontFamily: widget.overlay.fontFamily,
            entrance: previewEntrance,
          ),
        );
      },
    );
  }

  Widget _buildStyleTab(AppLocalizations l10n) {
    final overlay = widget.overlay;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      children: [
        Text(l10n.fontSize, style: Theme.of(context).textTheme.bodySmall),
        Slider(
          value: overlay.fontSize.clamp(minOverlayFontSize, maxOverlayFontSize),
          min: minOverlayFontSize,
          max: maxOverlayFontSize,
          divisions: 36,
          label: overlay.fontSize.round().toString(),
          activeColor: const Color(0xFF4CC9F0),
          onChanged: (v) {
            _emitOverlay(overlay.copyWith(fontSize: v));
          },
        ),
        Row(
          children: [
            Text(l10n.textStyle, style: Theme.of(context).textTheme.bodySmall),
            const Spacer(),
            _StudioStyleCycleButton(
              style: overlay.packItemId == null && overlay.templateId == null
                  ? overlay.style
                  : TextOverlayStyle.plain,
              color: overlay.color,
              tooltip: l10n.textStyleCycle,
              onPressed: _cycleStyle,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(l10n.textColor, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          children: _colors.map((c) {
            final selected = c.toARGB32() == overlay.color.toARGB32();
            return GestureDetector(
              onTap: () => _emitOverlay(overlay.copyWith(color: c)),
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? const Color(0xFF4CC9F0) : Colors.white24,
                    width: selected ? 3 : 1,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

class _TemplateTile extends StatelessWidget {
  const _TemplateTile({
    required this.selected,
    required this.label,
    required this.child,
    required this.onTap,
    this.badge,
  });

  final bool selected;
  final String label;
  final Widget child;
  final VoidCallback? onTap;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1C1F28),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? Colors.white : Colors.white12,
              width: selected ? 2.5 : 1,
            ),
          ),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 8, 6, 6),
                child: Column(
                  children: [
                    Expanded(child: Center(child: child)),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              if (badge != null) Positioned(right: 4, top: 4, child: badge!),
            ],
          ),
        ),
      ),
    );
  }
}

class _StudioStyleCycleButton extends StatelessWidget {
  const _StudioStyleCycleButton({
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
