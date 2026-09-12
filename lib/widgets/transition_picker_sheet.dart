import 'dart:math' as math;

import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/models/applied_transition.dart';
import 'package:aveditor/models/transition_item.dart';
import 'package:aveditor/services/transition_asset_store.dart';
import 'package:aveditor/services/transition_catalog_service.dart';
import 'package:aveditor/services/transition_engine.dart';
import 'package:aveditor/widgets/transition_preview_compositor.dart';
import 'package:flutter/material.dart';

/// Docked cut-transition editor (same shell as [TextStudioPanel]).
/// Height is owned by the editor dock; close with the header X ([onConfirm]).
class TransitionPickerPanel extends StatefulWidget {
  const TransitionPickerPanel({
    super.key,
    required this.initialSelectedId,
    required this.initialDuration,
    required this.minDuration,
    required this.maxDuration,
    this.initialParameters = const {},
    required this.onApplied,
    required this.onDurationChanged,
    this.onParametersChanged,
    required this.onConfirm,
  });

  static const headerHeight = 48.0;

  final String initialSelectedId;
  final Duration initialDuration;
  final Duration minDuration;
  final Duration maxDuration;
  final Map<String, double> initialParameters;
  final ValueChanged<AppliedTransition> onApplied;
  final ValueChanged<Duration> onDurationChanged;
  final ValueChanged<Map<String, double>>? onParametersChanged;
  final VoidCallback onConfirm;

  @override
  State<TransitionPickerPanel> createState() => _TransitionPickerPanelState();
}

class _TransitionPickerPanelState extends State<TransitionPickerPanel> {
  final _service = TransitionCatalogService.instance;
  final _assets = TransitionAssetStore.instance;
  var _loading = true;
  late String _selectedId;
  late Duration _duration;
  late Map<String, double> _parameters;
  String? _categoryId;
  /// Bumps on every tap so the selected tile can replay A→B.
  var _previewToken = 0;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.initialSelectedId;
    _duration = widget.initialDuration;
    _parameters = Map<String, double>.from(widget.initialParameters);
    _service.addListener(_onChanged);
    _assets.addListener(_onChanged);
    _bootstrap();
  }

  @override
  void dispose() {
    _service.removeListener(_onChanged);
    _assets.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _bootstrap() async {
    await Future.wait([
      _service.ensureInitialized(),
      _assets.ensureScanned(),
    ]);
    if (!mounted) return;
    final categories = _service.catalog.displayCategories;
    if (categories.isNotEmpty) {
      _categoryId ??= categories.first.id;
    }
    final selected = _service.itemById(_selectedId);
    if (selected != null && _parameters.isEmpty) {
      _parameters = selected.defaultParameters();
    }
    _duration = _clampDuration(_duration, selected);
    setState(() => _loading = false);
  }

  TransitionItem? get _selectedItem {
    if (_selectedId.isEmpty || _selectedId == 'none') {
      return TransitionItem.none;
    }
    return _service.itemById(_selectedId);
  }

  AppliedTransition _buildApplied(TransitionItem item, Duration duration) {
    if (item.isNone) return AppliedTransition.none;
    return AppliedTransition.fromDefinition(
      item,
      duration: duration,
      parameters: _parameters,
    );
  }

  (int minMs, int maxMs) _boundsFor(TransitionItem? item) {
    final segMin = widget.minDuration.inMilliseconds;
    final segMax = widget.maxDuration.inMilliseconds;
    if (item == null || item.isNone) {
      return (segMin, segMax <= segMin ? segMin + 1 : segMax);
    }
    final minMs = [segMin, item.minDurationMs].reduce((a, b) => a > b ? a : b);
    var maxMs = [segMax, item.maxDurationMs].reduce((a, b) => a < b ? a : b);
    if (maxMs <= minMs) maxMs = minMs + 1;
    return (minMs, maxMs);
  }

  Duration _clampDuration(Duration value, TransitionItem? item) {
    final (minMs, maxMs) = _boundsFor(item);
    return Duration(milliseconds: value.inMilliseconds.clamp(minMs, maxMs));
  }

  bool get _hasEffect {
    final item = _selectedItem;
    if (item != null) return !item.isNone;
    final id = _selectedId.trim();
    return id.isNotEmpty && id != 'none';
  }

  Future<void> _selectItem(TransitionItem item) async {
    if (item.needsDownload && !_assets.isInstalled(item)) {
      try {
        await _assets.install(item);
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Download failed')),
        );
        return;
      }
    }
    if (!mounted) return;

    final params = {
      ...item.defaultParameters(),
      ..._parameters,
    };
    final nextParams = <String, double>{
      for (final key in item.parameters.keys)
        key: params[key] ?? item.parameters[key]!.defaultValue,
    };

    setState(() {
      final sameItem = item.id == _selectedId;
      _selectedId = item.id;
      _parameters = nextParams;
      _previewToken++;
      if (!item.isNone) {
        // Re-tapping the selected effect must NOT wipe a user-adjusted length.
        if (sameItem) {
          _duration = _clampDuration(_duration, item);
        } else {
          _duration = _clampDuration(
            Duration(milliseconds: item.defaultDurationMs),
            item,
          );
        }
      }
    });

    final applied = _buildApplied(item, _duration);
    widget.onApplied(applied);
    if (!item.isNone) {
      widget.onDurationChanged(_duration);
      widget.onParametersChanged?.call(_parameters);
    }
  }

  void _onDurationSlider(double ms) {
    final next =
        _clampDuration(Duration(milliseconds: ms.round()), _selectedItem);
    if (next == _duration) return;
    setState(() => _duration = next);
    widget.onDurationChanged(next);
  }

  void _commitDuration() {
    final item = _selectedItem;
    if (item == null || item.isNone) return;
    widget.onDurationChanged(_duration);
    widget.onApplied(_buildApplied(item, _duration));
  }

  void _close() {
    _commitDuration();
    widget.onConfirm();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final categories = _service.catalog.displayCategories;
    TransitionCategory? category;
    if (categories.isNotEmpty) {
      category = categories.firstWhere(
        (c) => c.id == _categoryId,
        orElse: () => categories.first,
      );
    }
    final rawItems = category?.items ?? const <TransitionItem>[];
    // "None" on every tab so users can A/B compare against a hard cut.
    final items = [
      TransitionItem.none,
      ...rawItems.where((item) => !item.isNone),
    ];
    final (minMsInt, maxMsInt) = _boundsFor(_selectedItem);
    final minMs = minMsInt.toDouble();
    final maxMs = maxMsInt.toDouble();
    final showDuration = _hasEffect && !_loading && items.isNotEmpty;

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

          final header = _buildHeader(l10n, theme);

          if (maxH < TransitionPickerPanel.headerHeight) {
            return ClipRect(
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: maxH / TransitionPickerPanel.headerHeight,
                child: SizedBox(
                  height: TransitionPickerPanel.headerHeight,
                  width: constraints.maxWidth,
                  child: header,
                ),
              ),
            );
          }

          final bodyH = maxH - TransitionPickerPanel.headerHeight;
          final showChips = categories.length > 1 && bodyH >= 100;
          final showGrid = bodyH >= 88;
          final showDurationBar = showDuration && bodyH >= 140;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: TransitionPickerPanel.headerHeight,
                child: header,
              ),
              if (showChips)
                SizedBox(
                  height: 40,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.only(left: 12, right: 8),
                    itemCount: categories.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 4),
                    itemBuilder: (context, index) {
                      final cat = categories[index];
                      final selected = cat.id == (category?.id);
                      return InkWell(
                        onTap: () => setState(() => _categoryId = cat.id),
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                cat.title,
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 1.2,
                                  fontWeight: selected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: selected
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
                ),
              if (showGrid)
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : categories.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 24,
                              ),
                              child: Text(
                                l10n.transitionCatalogUnavailable,
                                style: const TextStyle(color: Colors.white70),
                              ),
                            )
                          : GridView.builder(
                              // Same grid metrics as TextStudioPanel._buildPackGrid.
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 4,
                                mainAxisSpacing: 8,
                                crossAxisSpacing: 8,
                                childAspectRatio: 0.85,
                              ),
                              itemCount: items.length,
                              itemBuilder: (context, index) {
                                final item = items[index];
                                final isSelected = item.id == _selectedId ||
                                    (item.isNone &&
                                        (_selectedId.isEmpty ||
                                            _selectedId == 'none'));
                                return _TransitionTile(
                                  item: item,
                                  label: item.isNone
                                      ? l10n.transitionNone
                                      : item.title,
                                  selected: isSelected,
                                  previewToken:
                                      isSelected ? _previewToken : 0,
                                  duration: _duration,
                                  parameters: Map<String, double>.from(
                                    isSelected
                                        ? _parameters
                                        : item.defaultParameters(),
                                  ),
                                  installed: _assets.isInstalled(item),
                                  downloading:
                                      _assets.isDownloading(item.id),
                                  onTap: () => _selectItem(item),
                                );
                              },
                            ),
                )
              else
                const Spacer(),
              if (showDurationBar)
                Material(
                  color: const Color(0xFF12141A),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: Row(
                      children: [
                        Text(
                          l10n.transitionDuration,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: Colors.white70,
                          ),
                        ),
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 2,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 7,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 14,
                              ),
                            ),
                            child: Slider(
                              value: _duration.inMilliseconds
                                  .toDouble()
                                  .clamp(minMs, maxMs),
                              min: minMs,
                              max: maxMs,
                              onChanged: _onDurationSlider,
                              onChangeEnd: (_) => _commitDuration(),
                            ),
                          ),
                        ),
                        Text(
                          '${(_duration.inMilliseconds / 1000).toStringAsFixed(1)}s',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: Colors.white70,
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHeader(AppLocalizations l10n, ThemeData theme) {
    return Row(
      children: [
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            l10n.transitionSheetTitle,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ),
        IconButton(
          onPressed: _close,
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          icon: const Icon(Icons.close, color: Colors.white70),
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}

class _TransitionTile extends StatefulWidget {
  const _TransitionTile({
    required this.item,
    required this.label,
    required this.selected,
    required this.previewToken,
    required this.duration,
    required this.parameters,
    required this.installed,
    required this.downloading,
    required this.onTap,
  });

  final TransitionItem item;
  final String label;
  final bool selected;
  final int previewToken;
  final Duration duration;
  final Map<String, double> parameters;
  final bool installed;
  final bool downloading;
  final VoidCallback onTap;

  @override
  State<_TransitionTile> createState() => _TransitionTileState();
}

class _TransitionTileState extends State<_TransitionTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _play;

  @override
  void initState() {
    super.initState();
    _play = AnimationController(vsync: this);
    if (widget.selected && !widget.item.isNone) {
      _runPreview();
    }
  }

  @override
  void didUpdateWidget(covariant _TransitionTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.selected) {
      _play.stop();
      _play.value = 0;
      return;
    }
    if (widget.item.isNone) {
      _play.value = 0;
      return;
    }
    if (widget.previewToken != oldWidget.previewToken ||
        (!oldWidget.selected && widget.selected) ||
        oldWidget.item.id != widget.item.id) {
      _runPreview();
    } else if (oldWidget.duration != widget.duration) {
      _play.duration = _previewDuration;
    }
  }

  @override
  void dispose() {
    _play.dispose();
    super.dispose();
  }

  Duration get _previewDuration {
    // Long enough to show both zoom-in and zoom-out phases in the tile.
    final ms = widget.duration.inMilliseconds.clamp(400, 1600);
    return Duration(milliseconds: ms);
  }

  void _runPreview() {
    _play.duration = _previewDuration;
    _play.forward(from: 0);
  }

  TransitionRenderPlan get _plan {
    if (widget.item.isNone) {
      return TransitionEngine.instance.plan(null);
    }
    return TransitionEngine.instance.plan(
      AppliedTransition.fromDefinition(
        widget.item,
        duration: widget.duration,
        parameters: widget.parameters,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showDownload =
        widget.item.needsDownload && !widget.installed && !widget.item.isNone;
    final radius = BorderRadius.circular(12);

    return InkWell(
      onTap: widget.downloading ? null : widget.onTap,
      borderRadius: radius,
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: AnimatedBuilder(
                  animation: _play,
                  builder: (context, _) {
                    return DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: radius,
                        border: Border.all(
                          color: widget.selected
                              ? Colors.white
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(1.5),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (widget.item.isNone)
                                const _TransitionSampleFrame(variant: 0)
                              else
                                TransitionAbCompositor(
                                  outgoing: const _TransitionSampleFrame(
                                    variant: 0,
                                  ),
                                  incoming: const _TransitionSampleFrame(
                                    variant: 1,
                                  ),
                                  t: widget.selected ? _play.value : 0,
                                  plan: _plan,
                                ),
                              if (widget.item.isNone)
                                const ColoredBox(
                                  color: Color(0x66000000),
                                  child: Center(
                                    child: Icon(
                                      Icons.block,
                                      color: Colors.white70,
                                      size: 22,
                                    ),
                                  ),
                                ),
                              if (widget.item.premium)
                                const Positioned(
                                  left: 4,
                                  top: 4,
                                  child: _PremiumBadge(),
                                ),
                              if (widget.downloading)
                                const Positioned(
                                  right: 4,
                                  top: 4,
                                  child: SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1.5,
                                    ),
                                  ),
                                )
                              else if (showDownload)
                                const Positioned(
                                  right: 4,
                                  top: 4,
                                  child: Icon(
                                    Icons.download,
                                    size: 12,
                                    color: Colors.white70,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: widget.selected ? Colors.white : Colors.white70,
              fontSize: 10,
              fontWeight:
                  widget.selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}

class _PremiumBadge extends StatelessWidget {
  const _PremiumBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: const Color(0xFF7C3AED),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Icon(Icons.diamond, size: 10, color: Colors.white),
    );
  }
}

/// Shared A / B sample stills for transition thumbnails (no network assets).
class _TransitionSampleFrame extends StatelessWidget {
  const _TransitionSampleFrame({required this.variant});

  /// 0 = image A (outgoing), 1 = image B (incoming).
  final int variant;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SampleFramePainter(variant: variant),
      child: const SizedBox.expand(),
    );
  }
}

class _SampleFramePainter extends CustomPainter {
  _SampleFramePainter({required this.variant});

  final int variant;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final sky = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: variant == 0
            ? const [Color(0xFF7EB6E8), Color(0xFFB8D4F0), Color(0xFFE8D5A3)]
            : const [Color(0xFF4A7AB5), Color(0xFF6FA0C8), Color(0xFFC4A574)],
      ).createShader(rect);
    canvas.drawRect(rect, sky);

    // Ground strip.
    final groundY = size.height * 0.62;
    final ground = Paint()
      ..color = variant == 0
          ? const Color(0xFF6B8F3C)
          : const Color(0xFF8B6B3C);
    canvas.drawRect(
      Rect.fromLTRB(0, groundY, size.width, size.height),
      ground,
    );

    if (variant == 0) {
      // Windmill-ish silhouette for A.
      final cx = size.width * 0.52;
      final cy = size.height * 0.48;
      final mast = Paint()
        ..color = Colors.white
        ..strokeWidth = size.width * 0.04
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(cx, groundY), Offset(cx, cy - size.height * 0.02), mast);
      final blade = Paint()
        ..color = Colors.white
        ..strokeWidth = size.width * 0.035
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i < 4; i++) {
        final a = (i * math.pi / 2) - 0.4;
        final len = size.width * 0.22;
        canvas.drawLine(
          Offset(cx, cy),
          Offset(cx + math.cos(a) * len, cy + math.sin(a) * len),
          blade,
        );
      }
    } else {
      // Hills + sun for B.
      final hill = Path()
        ..moveTo(0, size.height)
        ..lineTo(0, groundY + size.height * 0.05)
        ..quadraticBezierTo(
          size.width * 0.35,
          groundY - size.height * 0.12,
          size.width * 0.7,
          groundY + size.height * 0.02,
        )
        ..lineTo(size.width, groundY + size.height * 0.08)
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(hill, Paint()..color = const Color(0xFF5A7A3A));
      canvas.drawCircle(
        Offset(size.width * 0.78, size.height * 0.22),
        size.width * 0.12,
        Paint()..color = const Color(0xFFFFE08A),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SampleFramePainter oldDelegate) =>
      oldDelegate.variant != variant;
}
