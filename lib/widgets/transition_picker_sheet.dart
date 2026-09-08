import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/models/applied_transition.dart';
import 'package:aveditor/models/transition_item.dart';
import 'package:aveditor/services/transition_asset_store.dart';
import 'package:aveditor/services/transition_catalog_service.dart';
import 'package:aveditor/utils/editor_sheet_metrics.dart';
import 'package:flutter/material.dart';

/// Live cut-transition editor sheet. Applies as the user taps; dismiss with
/// the check button, or by dragging the top handle fully down.
/// Item grid scrolls independently; only the handle resizes the sheet.
///
/// Height stages match [EditorSheetMetrics]: entry (preview visible) → max →
/// dismiss.
Future<void> showTransitionPickerSheet(
  BuildContext context, {
  required String initialSelectedId,
  required Duration initialDuration,
  required Duration minDuration,
  required Duration maxDuration,
  Map<String, double> initialParameters = const {},
  required ValueChanged<AppliedTransition> onApplied,
  required ValueChanged<Duration> onDurationChanged,
  ValueChanged<Map<String, double>>? onParametersChanged,
}) {
  final metrics = EditorSheetMetrics.of(context);
  final entrySize = metrics.entryFraction;
  final minSize = metrics.minFraction;
  final maxSize = metrics.maxFraction;

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // Sheet owns vertical drag (resize / dismiss).
    enableDrag: false,
    barrierColor: Colors.transparent,
    backgroundColor: Colors.transparent,
    builder: (context) {
      return DraggableScrollableSheet(
        initialChildSize: entrySize,
        minChildSize: minSize,
        maxChildSize: maxSize,
        expand: false,
        snap: true,
        snapSizes: [entrySize],
        shouldCloseOnMinExtent: true,
        builder: (context, scrollController) {
          return TransitionPickerSheet(
            scrollController: scrollController,
            initialSelectedId: initialSelectedId,
            initialDuration: initialDuration,
            minDuration: minDuration,
            maxDuration: maxDuration,
            initialParameters: initialParameters,
            onApplied: onApplied,
            onDurationChanged: onDurationChanged,
            onParametersChanged: onParametersChanged,
          );
        },
      );
    },
  );
}

class TransitionPickerSheet extends StatefulWidget {
  const TransitionPickerSheet({
    super.key,
    required this.scrollController,
    required this.initialSelectedId,
    required this.initialDuration,
    required this.minDuration,
    required this.maxDuration,
    this.initialParameters = const {},
    required this.onApplied,
    required this.onDurationChanged,
    this.onParametersChanged,
  });

  final ScrollController scrollController;
  final String initialSelectedId;
  final Duration initialDuration;
  final Duration minDuration;
  final Duration maxDuration;
  final Map<String, double> initialParameters;
  final ValueChanged<AppliedTransition> onApplied;
  final ValueChanged<Duration> onDurationChanged;
  final ValueChanged<Map<String, double>>? onParametersChanged;

  @override
  State<TransitionPickerSheet> createState() => _TransitionPickerSheetState();
}

class _TransitionPickerSheetState extends State<TransitionPickerSheet> {
  final _service = TransitionCatalogService.instance;
  final _assets = TransitionAssetStore.instance;
  var _loading = true;
  late String _selectedId;
  late Duration _duration;
  late Map<String, double> _parameters;
  String? _categoryId;

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

  TransitionItem? get _selectedItem => _service.itemById(_selectedId);

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

  Color _parseAccent(String hex) {
    final cleaned = hex.replaceFirst('#', '');
    if (cleaned.length != 6) return const Color(0xFF6B7280);
    return Color(int.parse('FF$cleaned', radix: 16));
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

  void _closeSheet() {
    _commitDuration();
    Navigator.of(context).pop();
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
    final items = category?.items ?? const <TransitionItem>[];
    final (minMsInt, maxMsInt) = _boundsFor(_selectedItem);
    final minMs = minMsInt.toDouble();
    final maxMs = maxMsInt.toDouble();
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom +
        MediaQuery.paddingOf(context).bottom;
    final showDuration = _hasEffect && !_loading && items.isNotEmpty;

    return Material(
      color: theme.colorScheme.surface,
      elevation: 8,
      shadowColor: Colors.black54,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Handle always stays; remaining chrome collapses inside Expanded
            // so min-extent dismiss never overflows the outer Column.
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Sheet resize / dismiss: ONLY this handle strip uses the
                // DraggableScrollableSheet scrollController.
                SizedBox(
                  height: 36,
                  child: ListView(
                    controller: widget.scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.zero,
                    children: [
                      SizedBox(
                        height: 36,
                        child: Center(
                          child: Container(
                            width: 36,
                            height: 4,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.35),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, inner) {
                      if (inner.maxHeight < 48) {
                        return const SizedBox.shrink();
                      }
                      final showChips =
                          categories.length > 1 && inner.maxHeight >= 140;
                      final showGrid = inner.maxHeight >= 100;
                      final showDurationBar =
                          showDuration && inner.maxHeight >= 160;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    l10n.transitionSheetTitle,
                                    style:
                                        theme.textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: l10n.transitionApplied,
                                  onPressed: _closeSheet,
                                  icon: const Icon(Icons.check),
                                ),
                              ],
                            ),
                          ),
                          if (showChips) ...[
                            const SizedBox(height: 12),
                            SizedBox(
                              height: 36,
                              child: ListView.separated(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                scrollDirection: Axis.horizontal,
                                itemCount: categories.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(width: 8),
                                itemBuilder: (context, index) {
                                  final cat = categories[index];
                                  final selected = cat.id == (category?.id);
                                  return ChoiceChip(
                                    label: Text(cat.title),
                                    selected: selected,
                                    onSelected: (_) => setState(
                                      () => _categoryId = cat.id,
                                    ),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(height: 12),
                          ] else
                            const SizedBox(height: 4),
                          if (showGrid)
                            Expanded(
                              child: _loading
                                  ? const Center(
                                      child: CircularProgressIndicator(),
                                    )
                                  : categories.isEmpty
                                      ? Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 16,
                                            vertical: 24,
                                          ),
                                          child: Text(
                                            l10n.transitionCatalogUnavailable,
                                          ),
                                        )
                                      : GridView.builder(
                                          physics:
                                              const BouncingScrollPhysics(
                                            parent:
                                                AlwaysScrollableScrollPhysics(),
                                          ),
                                          padding: const EdgeInsets.fromLTRB(
                                            16,
                                            0,
                                            16,
                                            8,
                                          ),
                                          gridDelegate:
                                              const SliverGridDelegateWithFixedCrossAxisCount(
                                            crossAxisCount: 3,
                                            mainAxisSpacing: 10,
                                            crossAxisSpacing: 10,
                                            childAspectRatio: 0.86,
                                          ),
                                          itemCount: items.length,
                                          itemBuilder: (context, index) {
                                            final item = items[index];
                                            final isSelected =
                                                item.id == _selectedId ||
                                                    (item.isNone &&
                                                        (_selectedId
                                                                .isEmpty ||
                                                            _selectedId ==
                                                                'none'));
                                            return _TransitionTile(
                                              item: item,
                                              label: item.isNone
                                                  ? l10n.transitionNone
                                                  : item.title,
                                              accent:
                                                  _parseAccent(item.accent),
                                              thumbUrl: _service
                                                  .resolvedThumbnailUrl(item),
                                              selected: isSelected,
                                              installed: _assets
                                                  .isInstalled(item),
                                              downloading: _assets
                                                  .isDownloading(item.id),
                                              onTap: () => _selectItem(item),
                                            );
                                          },
                                        ),
                            )
                          else
                            const Spacer(),
                          if (showDurationBar)
                            Material(
                              color: theme.colorScheme.surface,
                              child: Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 0, 16, 8),
                                child: Row(
                                  children: [
                                    Text(
                                      l10n.transitionDuration,
                                      style: theme.textTheme.labelMedium,
                                    ),
                                    Expanded(
                                      child: SliderTheme(
                                        data: SliderTheme.of(context)
                                            .copyWith(
                                          trackHeight: 2,
                                          thumbShape:
                                              const RoundSliderThumbShape(
                                            enabledThumbRadius: 7,
                                          ),
                                          overlayShape:
                                              const RoundSliderOverlayShape(
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
                                          onChangeEnd: (_) =>
                                              _commitDuration(),
                                        ),
                                      ),
                                    ),
                                    Text(
                                      '${(_duration.inMilliseconds / 1000).toStringAsFixed(1)}s',
                                      style: theme.textTheme.labelMedium
                                          ?.copyWith(
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
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TransitionTile extends StatelessWidget {
  const _TransitionTile({
    required this.item,
    required this.label,
    required this.accent,
    required this.thumbUrl,
    required this.selected,
    required this.installed,
    required this.downloading,
    required this.onTap,
  });

  final TransitionItem item;
  final String label;
  final Color accent;
  final String? thumbUrl;
  final bool selected;
  final bool installed;
  final bool downloading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: downloading ? null : onTap,
      child: Column(
        children: [
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: accent.withValues(alpha: 0.22),
                border: Border.all(
                  color: selected
                      ? theme.colorScheme.primary
                      : accent.withValues(alpha: 0.55),
                  width: selected ? 2.5 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (thumbUrl != null && thumbUrl!.isNotEmpty)
                    Image.network(
                      thumbUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          _FallbackIcon(item: item, accent: accent),
                    )
                  else
                    _FallbackIcon(item: item, accent: accent),
                  if (item.premium)
                    Positioned(
                      top: 4,
                      left: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(
                          Icons.workspace_premium,
                          size: 12,
                          color: Color(0xFFFBBF24),
                        ),
                      ),
                    ),
                  if (item.needsDownload && !installed)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: downloading
                            ? const SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.5,
                                ),
                              )
                            : const Icon(
                                Icons.download_rounded,
                                size: 14,
                                color: Colors.white,
                              ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _FallbackIcon extends StatelessWidget {
  const _FallbackIcon({required this.item, required this.accent});

  final TransitionItem item;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(
        item.isNone ? Icons.block : Icons.animation_outlined,
        color: accent,
        size: 28,
      ),
    );
  }
}
