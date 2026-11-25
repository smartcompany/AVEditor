import 'dart:async';

import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/models/effect_access_tier.dart';
import 'package:aveditor/models/text_composition.dart';
import 'package:aveditor/models/text_entrance_animation.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/text_overlay_style.dart';
import 'package:aveditor/models/text_style_template.dart';
import 'package:aveditor/models/text_template_pack.dart';
import 'package:aveditor/services/text_template_pack_service.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/widgets/editor_dock_chrome.dart';
import 'package:aveditor/widgets/overlay_fonts.dart';
import 'package:aveditor/widgets/overlay_text_layout.dart';
import 'package:aveditor/widgets/text_entrance.dart';
import 'package:aveditor/utils/logged_snackbar.dart';
import 'package:aveditor/widgets/text_template_pack_browser.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

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
  late TextStudioTab _tab;

  final _packService = TextTemplatePackService.instance;
  final _tabBarKey = GlobalKey();

  /// True once bundled/cache is ready to paint (before silent version check).
  var _cacheVisible = false;

  static TextStudioTab tabForOverlay(TextOverlay overlay) {
    final pack = TextTemplatePackService.instance.itemById(overlay.packItemId);
    if (pack != null && pack.kind == 'template') {
      return TextStudioTab.textTemplates;
    }
    return TextStudioTab.templates;
  }

  @override
  void initState() {
    super.initState();
    _tab = tabForOverlay(widget.overlay);
    _packService.addListener(_onPackService);
    // Cache first → silent version check → loading bar only if replacing.
    unawaited(_syncCatalogOnOpen());
  }

  Future<void> _syncCatalogOnOpen() async {
    await _packService.ensureInitialized();
    if (!mounted) return;
    // Never reset [_tab] here — catalog reload must not undo the user's tab.
    setState(() => _cacheVisible = _packService.hasItems);
    _prefetchPackFonts();
    await _packService.syncOnPanelOpen();
    if (!mounted) return;
    setState(() => _cacheVisible = _packService.hasItems);
    _prefetchPackFonts();
  }

  @override
  void didUpdateWidget(covariant TextStudioPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only follow overlay when the selection changes — not on pack apply /
    // catalog refresh, which would yank the tab out from under the user.
    if (oldWidget.overlay.id != widget.overlay.id) {
      final next = tabForOverlay(widget.overlay);
      if (next != _tab) _tab = next;
    }
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
    // Intrinsic default look — never keep pack font/color from the last tile.
    _emitOverlay(
      widget.overlay.copyWith(
        packItemId: null,
        templateId: null,
        style: TextOverlayStyle.plain,
        fontFamily: null,
        color: Colors.white,
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
      } catch (e, st) {
        if (!mounted) return;
        showLoggedSnackBar(
          context,
          'Download failed',
          error: e,
          stackTrace: st,
        );
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
    final current = widget.overlay;
    var nextEnd = current.end;
    if (item.animation.isContinuous) {
      final spanMs = item.animation.durationMs.clamp(1000, 30000);
      nextEnd = current.start + Duration(milliseconds: spanMs);
      if (nextEnd <= current.start) {
        nextEnd = current.start + const Duration(seconds: 18);
      }
    }
    // Text templates: seed sampleText when body is unset, or still equals the
    // previous pack's sample (user hasn't edited). Keep real user edits.
    // Effects stay as-typed. Multi-slot compositions also reseed single-line.
    final seededText = () {
      if (item.kind != 'template') return null;
      final seed = _packSampleBody(item);
      final t = current.text.trim();
      final hint = context.l10n.textOverlayHint.trim();
      final unset = t.isEmpty ||
          t == kEmptyOverlayLayoutSample ||
          t == hint ||
          t == context.l10n.addText.trim();
      if (unset) return seed;
      final prevPack = _packService.itemById(current.packItemId);
      if (prevPack != null &&
          prevPack.kind == 'template' &&
          prevPack.id != item.id &&
          t == _packSampleBody(prevPack).trim()) {
        return seed;
      }
      if (item.hasComposition) {
        final slotCount = item.composition!.slots.length;
        if (slotCount > 1 && !t.contains('\n')) return seed;
      }
      return null;
    }();
    _emitOverlay(
      current.copyWith(
        packItemId: item.id,
        templateId: null,
        style: TextOverlayStyle.plain,
        fontFamily: fontId ?? current.fontFamily,
        color: seededColor ?? current.color,
        end: nextEnd,
        text: seededText ?? current.text,
        // Clear override so pack animation (templates) can apply;
        // static effects ship with no animation.
        animationId: null,
        animationDurationMs: null,
      ),
    );
  }

  /// Server [sampleText], else composition defaults, else template fallback.
  static String _packSampleBody(TextTemplatePackItem item) {
    final sample = item.sampleText?.trim();
    if (sample != null && sample.isNotEmpty) return item.sampleText!;
    if (item.hasComposition) return item.composition!.sampleText;
    return TextTemplatePackItem.defaultTemplateSampleText;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return EditorDockChrome.shell(
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

          final applyingUpdate = _packService.isSyncing;
          final showCache = _cacheVisible && _packService.hasItems;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: TextStudioPanel.headerHeight,
                child: header,
              ),
              if (applyingUpdate) EditorDockChrome.progressBar(),
              Expanded(
                child: !showCache || applyingUpdate
                    ? EditorDockChrome.loadingSpinner()
                    : _buildTabBody(l10n),
              ),
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
        EditorDockChrome.closeButton(
          onPressed: widget.onConfirm,
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
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
        return EditorDockTabLabel(
          label: label,
          selected: _tab == tab,
          onTap: () => setState(() => _tab = tab),
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
          includeDefault: true,
        );
      case TextStudioTab.textTemplates:
        return _buildPackGrid(
          l10n,
          kind: 'template',
          loopSelectedAnimation: true,
        );
    }
  }

  Widget _buildPackGrid(
    AppLocalizations l10n, {
    required String kind,
    bool loopSelectedAnimation = false,
    bool includeDefault = false,
  }) {
    // Category id matches the dashboard split; kind is coerced on parse.
    final wantTemplates = kind == 'template';
    final packItems = <TextTemplatePackItem>[
      for (final category in _packService.catalog.categories)
        if (wantTemplates == (category.id == 'templates'))
          ...category.items,
    ];
    final defaultOffset = includeDefault ? 1 : 0;
    final defaultTileText = kind == 'template'
        ? TextTemplatePackItem.defaultTemplateSampleText
        : TextTemplatePackItem.defaultEffectSampleText;

    if (packItems.isEmpty && !includeDefault) {
      final err = _packService.lastError;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            err == null || err.isEmpty
                ? 'No catalog items'
                : 'Catalog unavailable\n$err',
            textAlign: TextAlign.center,
            style: GoogleFonts.dmSans(color: AppTheme.muted, fontSize: 13),
          ),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.85,
      ),
      itemCount: packItems.length + defaultOffset,
      itemBuilder: (context, index) {
        if (includeDefault && index == 0) {
          final selected = widget.overlay.packItemId == null;
          return EditorDockTile(
            selected: selected,
            label: l10n.textStudioDefault,
            onTap: _selectDefaultLook,
            child: OverlayTextDisplay(
              text: defaultTileText,
              // Fixed catalog look — do not bind to the live overlay color/font
              // or every tile jumps when another pack is selected.
              color: AppTheme.ink,
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
        final tileText = pack.tilePreviewText;
        final loopTile = loopSelectedAnimation && selected;
        return EditorDockTile(
          selected: selected,
          label: pack.title,
          badge: pack.accessTier.isPaid
              ? Text(
                  pack.accessTier.badgeLabel,
                  style: GoogleFonts.dmSans(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: pack.accessTier == EffectAccessTier.pro
                        ? AppTheme.gradientPurple
                        : AppTheme.accentCyan,
                  ),
                )
              : downloading
              ? const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: AppTheme.accent,
                  ),
                )
              : !installed
              ? Icon(
                  Icons.download_rounded,
                  size: 12,
                  color: AppTheme.muted.withValues(alpha: 0.85),
                )
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
                text: tileText,
                color: _catalogPreviewAccent(pack.style),
                fontFamily: pack.style.preferredFontId,
                template: pack.style,
                composition: pack.composition,
                animation: pack.animation,
                loopAnimation: loopTile,
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
    this.composition,
    this.animation = TextEntranceAnimation.none,
    this.loopAnimation = false,
  });

  final String text;
  final Color color;
  final TextStyleTemplate template;
  final String? fontFamily;
  final TextComposition? composition;
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
  /// Star Crawl / Credits are ~16–18s on the canvas; compress for the tile.
  static const _continuousTileMs = 4200;

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

  int get _loopMs {
    final anim = widget.animation;
    if (anim.isContinuous) return _continuousTileMs;
    return anim.durationMs.clamp(100, 10000) + _holdMs;
  }

  /// Full crawl factors throw text far outside a ~70px tile; shrink for preview.
  TextEntranceAnimation get _tileAnimation {
    final anim = widget.animation;
    if (!anim.isContinuous) return anim;
    return anim.copyWith(
      durationMs: _continuousTileMs,
      scrollStartFactor: 2.8,
      scrollEndFactor: -3.6,
    );
  }

  void _syncLoop() {
    final anim = widget.animation;
    if (widget.loopAnimation && !anim.isNone) {
      _loop.duration = Duration(milliseconds: _loopMs);
      // Restart from 0 so selecting Star Crawl / Credits immediately scrolls.
      _loop
        ..stop()
        ..repeat();
    } else {
      _loop.stop();
      _loop.value = 1;
    }
  }

  TextEntranceState _entranceAt(double controllerValue, double fontSize) {
    final anim = widget.animation;
    if (!widget.loopAnimation || anim.isNone) {
      return TextEntranceState.fullyVisible;
    }
    final preview = _tileAnimation;
    final entranceMs = anim.isContinuous
        ? _continuousTileMs.toDouble()
        : anim.durationMs.clamp(100, 10000).toDouble();
    final totalMs =
        anim.isContinuous ? entranceMs : entranceMs + _holdMs;
    final elapsed = controllerValue * totalMs;
    final progress = (elapsed / entranceMs).clamp(0.0, 1.0);
    return evaluateTextEntrance(
      animationId: preview.id,
      animation: preview,
      text: widget.text,
      progress: progress,
      fontSize: fontSize,
      slotCount: widget.composition?.paintedSlotCount(widget.text),
    );
  }

  @override
  Widget build(BuildContext context) {
    final multiline = widget.text.contains('\n');
    final fontSize = multiline
        ? 11.0
        : (widget.text.length > 2 ? 14.0 : 18.0);
    final maxWidth = multiline
        ? 78.0
        : (widget.text.length > 2 ? 72.0 : 64.0);

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
        composition: widget.composition,
        entrance: entrance,
      );
    }

    if (!widget.loopAnimation || widget.animation.isNone) {
      return preview(TextEntranceState.fullyVisible);
    }

    return AnimatedBuilder(
      animation: _loop,
      builder: (context, _) => preview(_entranceAt(_loop.value, fontSize)),
    );
  }
}

