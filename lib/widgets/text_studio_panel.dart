import 'dart:async';

import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/models/text_entrance_animation.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/text_overlay_style.dart';
import 'package:aveditor/models/text_style_template.dart';
import 'package:aveditor/models/text_template_pack.dart';
import 'package:aveditor/services/text_template_pack_service.dart';
import 'package:aveditor/widgets/overlay_fonts.dart';
import 'package:aveditor/widgets/overlay_text_layout.dart';
import 'package:aveditor/widgets/text_entrance.dart';
import 'package:aveditor/widgets/text_template_pack_browser.dart';
import 'package:flutter/material.dart';

enum TextStudioTab { templates, textTemplates }

/// CapCut-style docked text studio: Text effects + text templates.
/// Dock height is owned by the editor; close with the header X ([onConfirm]).
class TextStudioPanel extends StatefulWidget {
  const TextStudioPanel({
    super.key,
    required this.overlay,
    required this.onChanged,
    required this.onConfirm,
  });

  /// Tabs + close control.
  static const headerHeight = 48.0;

  final TextOverlay overlay;
  final ValueChanged<TextOverlay> onChanged;
  final VoidCallback onConfirm;

  @override
  State<TextStudioPanel> createState() => _TextStudioPanelState();
}

class _TextStudioPanelState extends State<TextStudioPanel> {
  TextStudioTab _tab = TextStudioTab.templates;

  final _packService = TextTemplatePackService.instance;
  final _tabBarKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _packService.addListener(_onPackService);
    _packService.ensureInitialized().then((_) {
      if (mounted) _prefetchPackFonts();
    });
  }

  void _prefetchPackFonts() {
    for (final item in _packService.catalog.allItems) {
      final fontId = item.style.preferredFontId;
      if (fontId == null) continue;
      unawaited(
        OverlayFonts.ensureLoaded(fontId).then((_) {
          if (mounted) setState(() {});
        }),
      );
    }
  }

  @override
  void dispose() {
    _packService.removeListener(_onPackService);
    super.dispose();
  }

  void _onPackService() {
    if (mounted) {
      setState(() {});
      _prefetchPackFonts();
    }
  }

  void _emitOverlay(TextOverlay next) {
    widget.onChanged(
      fitOverlayBoxToText(next, emptyPlaceholder: context.l10n.textOverlayHint),
    );
  }

  void _selectDefaultLook() {
    _emitOverlay(
      widget.overlay.copyWith(
        packItemId: null,
        templateId: null,
        // Clear pack-driven entrance; static basic text has none.
        animationId: null,
        animationDurationMs: null,
      ),
    );
  }

  /// Catalog swatch color for a pack tile — independent of the live overlay.
  static Color _catalogPreviewAccent(TextStyleTemplate style) {
    if (!style.fillUseAccent) {
      if (style.fillArgb != null) return Color(style.fillArgb!);
      final gradient = style.fillGradient;
      if (gradient != null && gradient.colorArgb.isNotEmpty) {
        return Color(gradient.colorArgb[gradient.colorArgb.length ~/ 2]);
      }
    }
    return Colors.white;
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
    final fontId = item.style.preferredFontId;
    // Load pack font before fitting so Hangul is not measured with a missing
    // face (zero-width → ultra-narrow box → vertical wrap).
    if (fontId != null) {
      await OverlayFonts.ensureLoaded(fontId);
      if (!mounted) return;
    }
    // Seed user color from the pack default so the color tray can recolor it.
    final style = item.style;
    Color? seededColor;
    if (!style.fillUseAccent) {
      if (style.fillArgb != null) {
        seededColor = Color(style.fillArgb!);
      } else if (style.fillGradient != null &&
          style.fillGradient!.colorArgb.isNotEmpty) {
        final colors = style.fillGradient!.colorArgb;
        seededColor = Color(colors[colors.length ~/ 2]);
      }
    }
    _emitOverlay(
      widget.overlay.copyWith(
        packItemId: item.id,
        templateId: null,
        style: TextOverlayStyle.plain,
        fontFamily: fontId ?? widget.overlay.fontFamily,
        color: seededColor ?? widget.overlay.color,
        // Clear override so pack animation (templates) can apply;
        // static effects ship with no animation.
        animationId: null,
        animationDurationMs: null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return Material(
      color: const Color(0xFF12141A),
      elevation: 8,
      shadowColor: Colors.black54,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxH = constraints.maxHeight;
          if (!maxH.isFinite || maxH < 1) {
            return const SizedBox.shrink();
          }

          final header = KeyedSubtree(
            key: _tabBarKey,
            child: _buildHeader(l10n),
          );

          // Dock can be dragged under the preferred header height; clip instead
          // of asserting (IconButton / tab bar want ~48px).
          if (maxH < TextStudioPanel.headerHeight) {
            return ClipRect(
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: maxH / TextStudioPanel.headerHeight,
                child: SizedBox(
                  height: TextStudioPanel.headerHeight,
                  width: constraints.maxWidth,
                  child: header,
                ),
              ),
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: TextStudioPanel.headerHeight,
                child: header,
              ),
              Expanded(child: _buildTabBody(l10n)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHeader(AppLocalizations l10n) {
    return Row(
      children: [
        Expanded(child: _buildTabBar(l10n)),
        IconButton(
          onPressed: widget.onConfirm,
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          icon: const Icon(Icons.close, color: Colors.white70),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildTabBar(AppLocalizations l10n) {
    final labeled = <(TextStudioTab, String)>[
      (TextStudioTab.templates, l10n.textStudioTabTemplates),
      (TextStudioTab.textTemplates, l10n.textStudioTabTextTemplates),
    ];

    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.only(left: 12),
      itemCount: labeled.length,
      separatorBuilder: (_, _) => const SizedBox(width: 4),
      itemBuilder: (context, index) {
        final (tab, label) = labeled[index];
        final selected = _tab == tab;
        return InkWell(
          onTap: () => setState(() => _tab = tab),
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
                    color: selected ? Colors.white : Colors.white60,
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
    );
  }

  Widget _buildTabBody(AppLocalizations l10n) {
    switch (_tab) {
      case TextStudioTab.templates:
        return _buildPackGrid(
          l10n,
          kind: 'effect',
          previewText: 'Aa',
          includeDefault: true,
        );
      case TextStudioTab.textTemplates:
        return _buildPackGrid(
          l10n,
          kind: 'template',
          previewText: 'Hello',
          loopSelectedAnimation: true,
        );
    }
  }

  Widget _buildPackGrid(
    AppLocalizations l10n, {
    required String kind,
    required String previewText,
    bool loopSelectedAnimation = false,
    bool includeDefault = false,
  }) {
    final packItems = <TextTemplatePackItem>[
      for (final category in _packService.catalog.categories)
        for (final item in category.items)
          if (item.kind == kind) item,
    ];
    final defaultOffset = includeDefault ? 1 : 0;

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.85,
      ),
      itemCount: packItems.length + defaultOffset,
      itemBuilder: (context, index) {
        if (includeDefault && index == 0) {
          final selected = widget.overlay.packItemId == null;
          return _TemplateTile(
            selected: selected,
            label: l10n.textStudioDefault,
            onTap: _selectDefaultLook,
            child: OverlayTextDisplay(
              text: previewText,
              // Fixed catalog look — do not bind to the live overlay color/font
              // or every tile jumps when another pack is selected.
              color: Colors.white,
              fontSize: 22,
              maxWidth: 64,
              template: templateForBasicStyle(TextOverlayStyle.plain),
            ),
          );
        }
        final pack = packItems[index - defaultOffset];
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
            clipBehavior: Clip.none,
            children: [
              if (pack.hasLottie && installed)
                PackLottieDecoration(
                  packItemId: pack.id,
                  width: 70,
                  height: 44,
                ),
              _PackAaPreview(
                text: previewText,
                color: _catalogPreviewAccent(pack.style),
                fontFamily: pack.style.preferredFontId,
                template: pack.style,
                animation: pack.animation,
                loopAnimation: loopSelectedAnimation && selected,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PackAaPreview extends StatefulWidget {
  const _PackAaPreview({
    required this.text,
    required this.color,
    required this.template,
    this.fontFamily,
    this.animation = TextEntranceAnimation.none,
    this.loopAnimation = false,
  });

  final String text;
  final Color color;
  final TextStyleTemplate template;
  final String? fontFamily;
  final TextEntranceAnimation animation;
  final bool loopAnimation;

  @override
  State<_PackAaPreview> createState() => _PackAaPreviewState();
}

class _PackAaPreviewState extends State<_PackAaPreview>
    with SingleTickerProviderStateMixin {
  var _fontReady = false;
  late final AnimationController _loop;

  static const _holdMs = 700;

  @override
  void initState() {
    super.initState();
    _loop = AnimationController(vsync: this);
    _loadFont();
    _syncLoop();
  }

  @override
  void didUpdateWidget(covariant _PackAaPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fontFamily != widget.fontFamily) {
      _fontReady = false;
      _loadFont();
    }
    if (oldWidget.loopAnimation != widget.loopAnimation ||
        oldWidget.animation.id != widget.animation.id ||
        oldWidget.animation.durationMs != widget.animation.durationMs) {
      _syncLoop();
    }
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  Future<void> _loadFont() async {
    final id = widget.fontFamily;
    if (id == null || id.isEmpty) {
      if (mounted) setState(() => _fontReady = true);
      return;
    }
    await OverlayFonts.ensureLoaded(id);
    if (mounted) setState(() => _fontReady = true);
  }

  void _syncLoop() {
    final anim = widget.animation;
    if (widget.loopAnimation && !anim.isNone) {
      final totalMs = anim.durationMs.clamp(100, 10000) + _holdMs;
      _loop.duration = Duration(milliseconds: totalMs);
      if (!_loop.isAnimating) {
        _loop.repeat();
      }
    } else {
      _loop.stop();
      _loop.value = 1;
    }
  }

  TextEntranceState _entranceAt(double controllerValue) {
    final anim = widget.animation;
    if (!widget.loopAnimation || anim.isNone) {
      return TextEntranceState.fullyVisible;
    }
    final entranceMs = anim.durationMs.clamp(100, 10000).toDouble();
    final totalMs = entranceMs + _holdMs;
    final elapsed = controllerValue * totalMs;
    final progress = (elapsed / entranceMs).clamp(0.0, 1.0);
    return evaluateTextEntrance(
      animationId: anim.id,
      text: widget.text,
      progress: progress,
      fontSize: 14,
    );
  }

  @override
  Widget build(BuildContext context) {
    final fontSize = widget.text.length > 2 ? 14.0 : 18.0;
    final maxWidth = widget.text.length > 2 ? 72.0 : 64.0;

    // Until Google Fonts finish loading, paint with the bundled overlay font
    // so tiles like Pastel are never blank.
    Widget preview(TextEntranceState entrance) {
      return OverlayTextDisplay(
        text: widget.text,
        color: widget.color,
        fontSize: fontSize,
        maxWidth: maxWidth,
        fontFamily: _fontReady ? widget.fontFamily : null,
        template: widget.template,
        entrance: entrance,
      );
    }

    if (!widget.loopAnimation || widget.animation.isNone) {
      return preview(TextEntranceState.fullyVisible);
    }

    return AnimatedBuilder(
      animation: _loop,
      builder: (context, _) => preview(_entranceAt(_loop.value)),
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
                    Expanded(
                      child: Center(child: ClipRect(child: child)),
                    ),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
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
