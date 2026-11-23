import 'dart:async';

import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/services/giphy_service.dart';
import 'package:aveditor/services/sticker_storage_service.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:flutter/material.dart';

/// Result of picking a Giphy sticker and caching it under the project.
class GiphyStickerPick {
  const GiphyStickerPick({
    required this.relativePath,
    required this.sticker,
  });

  final String relativePath;
  final GiphySticker sticker;
}

/// Category tabs — label shown in UI; [query] is sent to Giphy (`null` = trending).
enum _StickerTab {
  sticker(label: 'Sticker', query: null),
  funny(label: 'Funny', query: 'funny'),
  cats(label: 'Cats', query: 'cats'),
  dogs(label: 'Dogs', query: 'dogs'),
  party(label: 'Party', query: 'party');

  const _StickerTab({required this.label, required this.query});

  final String label;
  final String? query;
}

/// Docked sticker browser (same shell as [TransitionPickerPanel] / text studio).
///
/// Height is owned by the editor dock; close with the header X ([onConfirm]).
/// Tapping a sticker downloads it and calls [onPicked] (panel stays open for
/// multi-add unless the editor closes it).
class GiphyStickerPickerPanel extends StatefulWidget {
  const GiphyStickerPickerPanel({
    super.key,
    required this.projectDir,
    required this.onPicked,
    required this.onConfirm,
  });

  static const headerHeight = 48.0;

  final String projectDir;
  final ValueChanged<GiphyStickerPick> onPicked;
  final VoidCallback onConfirm;

  @override
  State<GiphyStickerPickerPanel> createState() =>
      _GiphyStickerPickerPanelState();
}

class _GiphyStickerPickerPanelState extends State<GiphyStickerPickerPanel> {
  final _giphy = GiphyService();
  final _storage = StickerStorageService();
  final _search = TextEditingController();
  Timer? _debounce;

  var _tab = _StickerTab.sticker;
  List<GiphySticker> _items = const [];
  bool _loading = true;
  String? _error;
  String? _busyId;
  int _loadGen = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// Free-text search wins when non-empty; otherwise the selected tab.
  Future<void> _load({String? searchOverride}) async {
    final gen = ++_loadGen;
    if (!GiphyService.hasApiKey) {
      setState(() {
        _loading = false;
        _error = 'missing_key';
        _items = const [];
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final typed = (searchOverride ?? _search.text).trim();
      final List<GiphySticker> items;
      if (typed.isNotEmpty) {
        items = await _giphy.search(typed);
      } else {
        final tabQuery = _tab.query;
        items = tabQuery == null
            ? await _giphy.trending()
            : await _giphy.search(tabQuery);
      }
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _loading = false;
        _error = e.toString();
        _items = const [];
      });
    }
  }

  void _onQueryChanged(String value) {
    setState(() {}); // refresh tab selection chrome while typing
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_load(searchOverride: value));
    });
  }

  void _selectTab(_StickerTab tab) {
    if (_tab == tab && _search.text.trim().isEmpty) return;
    _debounce?.cancel();
    _search.clear();
    setState(() {
      _tab = tab;
      _items = const [];
    });
    unawaited(_load(searchOverride: ''));
  }

  Future<void> _pick(GiphySticker sticker) async {
    if (_busyId != null) return;
    setState(() => _busyId = sticker.id);
    try {
      final relative = await _storage.downloadGiphySticker(
        projectDir: widget.projectDir,
        sticker: sticker,
      );
      if (!mounted) return;
      widget.onPicked(
        GiphyStickerPick(relativePath: relative, sticker: sticker),
      );
      setState(() => _busyId = null);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busyId = null);
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.showSnackBar(
        SnackBar(content: Text(context.l10n.stickerDownloadFailed)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxH = constraints.maxHeight;
        final header = _buildHeader();

        if (maxH < GiphyStickerPickerPanel.headerHeight) {
          return ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: maxH / GiphyStickerPickerPanel.headerHeight,
              child: SizedBox(
                height: GiphyStickerPickerPanel.headerHeight,
                width: constraints.maxWidth,
                child: header,
              ),
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
              child: header,
            ),
            SizedBox(
              height: 36,
              child: _buildTabBar(),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _buildBody(l10n),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                l10n.stickerPoweredByGiphy,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppTheme.muted,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Search field + close — no title row.
  Widget _buildHeader() {
    final l10n = context.l10n;
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _search,
            onChanged: _onQueryChanged,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: l10n.stickerSearchHint,
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              filled: true,
              fillColor: AppTheme.surfaceElevated,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        IconButton(
          onPressed: widget.onConfirm,
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          icon: const Icon(Icons.close, color: Colors.white70),
        ),
      ],
    );
  }

  Widget _buildTabBar() {
    const tabs = _StickerTab.values;
    final searching = _search.text.trim().isNotEmpty;
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: tabs.length,
      separatorBuilder: (_, _) => const SizedBox(width: 4),
      itemBuilder: (context, index) {
        final tab = tabs[index];
        final selected = !searching && _tab == tab;
        return InkWell(
          onTap: () => _selectTab(tab),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tab.label,
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

  Widget _buildBody(AppLocalizations l10n) {
    if (_error == 'missing_key') {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.stickerApiKeyMissing,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.muted),
          ),
        ),
      );
    }
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.stickerLoadFailed,
              style: const TextStyle(color: AppTheme.muted),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => unawaited(_load()),
              child: Text(l10n.retry),
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          l10n.stickerEmpty,
          style: const TextStyle(color: AppTheme.muted),
        ),
      );
    }

    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final item = _items[index];
        final busy = _busyId == item.id;
        return Material(
          color: AppTheme.surfaceElevated,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: busy ? null : () => unawaited(_pick(item)),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.network(
                  item.previewUrl,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Icon(
                    Icons.broken_image_outlined,
                    color: AppTheme.muted,
                  ),
                ),
                if (busy)
                  const ColoredBox(
                    color: Color(0x66000000),
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
