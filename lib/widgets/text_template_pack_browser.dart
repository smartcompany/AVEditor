import 'dart:io';

import 'package:aveditor/models/text_template_pack.dart';
import 'package:aveditor/services/text_template_pack_service.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/widgets/overlay_text_layout.dart';
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

/// Plays the decorative Lottie layer for a pack item behind editable text.
class PackLottieDecoration extends StatefulWidget {
  const PackLottieDecoration({
    super.key,
    required this.packItemId,
    required this.width,
    required this.height,
  });

  final String packItemId;
  final double width;
  final double height;

  @override
  State<PackLottieDecoration> createState() => _PackLottieDecorationState();
}

class _PackLottieDecorationState extends State<PackLottieDecoration>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  String? _asset;
  File? _file;
  var _loading = true;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
    _resolve();
  }

  @override
  void didUpdateWidget(covariant PackLottieDecoration oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.packItemId != widget.packItemId) {
      _resolve();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _resolve() async {
    setState(() => _loading = true);
    final item =
        TextTemplatePackService.instance.itemById(widget.packItemId);
    if (item == null || !item.hasLottie) {
      if (!mounted) return;
      setState(() {
        _asset = null;
        _file = null;
        _loading = false;
      });
      return;
    }

    final source =
        await TextTemplatePackService.instance.resolveLottieSource(item);
    if (!mounted) return;
    setState(() {
      _asset = source.asset;
      _file = source.file;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return SizedBox(width: widget.width, height: widget.height);
    if (_asset == null && _file == null) {
      return SizedBox(width: widget.width, height: widget.height);
    }

    final child = _asset != null
        ? Lottie.asset(
            _asset!,
            controller: _controller,
            width: widget.width,
            height: widget.height,
            fit: BoxFit.contain,
            onLoaded: (composition) {
              _controller
                ..duration = composition.duration
                ..repeat();
            },
          )
        : Lottie.file(
            _file!,
            controller: _controller,
            width: widget.width,
            height: widget.height,
            fit: BoxFit.contain,
            onLoaded: (composition) {
              _controller
                ..duration = composition.duration
                ..repeat();
            },
          );

    return IgnorePointer(child: child);
  }
}

Future<void> showTextTemplatePackBrowser({
  required BuildContext context,
  required ValueChanged<TextTemplatePackItem> onSelected,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF12141A),
    barrierColor: Colors.transparent,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => _TextTemplatePackBrowser(onSelected: onSelected),
  );
}

class _TextTemplatePackBrowser extends StatefulWidget {
  const _TextTemplatePackBrowser({required this.onSelected});

  final ValueChanged<TextTemplatePackItem> onSelected;

  @override
  State<_TextTemplatePackBrowser> createState() =>
      _TextTemplatePackBrowserState();
}

class _TextTemplatePackBrowserState extends State<_TextTemplatePackBrowser> {
  final _search = TextEditingController();
  final _service = TextTemplatePackService.instance;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _service.addListener(_onService);
    _service.ensureInitialized();
  }

  @override
  void dispose() {
    _service.removeListener(_onService);
    _search.dispose();
    super.dispose();
  }

  void _onService() {
    if (mounted) setState(() {});
  }

  Future<void> _onTap(TextTemplatePackItem item) async {
    if (!_service.isInstalled(item)) {
      try {
        await _service.install(item);
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Download failed')),
        );
        return;
      }
    }
    if (!mounted) return;
    Navigator.pop(context);
    // Apply after the sheet closes so inline edit can take focus.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onSelected(item);
    });
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.72;
    final categories = _service.catalog.categories;
    final q = _query.trim().toLowerCase();

    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 10),
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: 'Search text templates',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.white10,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          if (_service.lastError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Remote catalog unavailable — showing bundled packs',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.orangeAccent,
                ),
              ),
            ),
          Expanded(
            child: !_service.isReady
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    itemCount: categories.length,
                    itemBuilder: (context, index) {
                      final category = categories[index];
                      final items = category.items.where((item) {
                        if (q.isEmpty) return true;
                        return item.title.toLowerCase().contains(q) ||
                            item.id.toLowerCase().contains(q);
                      }).toList();
                      if (items.isEmpty) return const SizedBox.shrink();

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10, top: 8),
                            child: Text(
                              category.title,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: items.length,
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              mainAxisSpacing: 10,
                              crossAxisSpacing: 10,
                              childAspectRatio: 1.15,
                            ),
                            itemBuilder: (context, i) {
                              final item = items[i];
                              return _PackTile(
                                item: item,
                                installed: _service.isInstalled(item),
                                downloading: _service.isDownloading(item.id),
                                onTap: () => _onTap(item),
                              );
                            },
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _PackTile extends StatelessWidget {
  const _PackTile({
    required this.item,
    required this.installed,
    required this.downloading,
    required this.onTap,
  });

  final TextTemplatePackItem item;
  final bool installed;
  final bool downloading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1C1F28),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: downloading ? null : onTap,
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  children: [
                    Expanded(
                      child: Stack(
                        alignment: Alignment.center,
                        clipBehavior: Clip.none,
                        children: [
                          if (item.hasLottie && installed)
                            IgnorePointer(
                              child: Opacity(
                                opacity: 0.9,
                                child: PackLottieDecoration(
                                  packItemId: item.id,
                                  width: 150,
                                  height: 88,
                                ),
                              ),
                            ),
                          // Always show sample text so the style is obvious.
                          OverlayTextDisplay(
                            text: item.title,
                            color: AppTheme.accent,
                            fontSize: 26,
                            maxWidth: 150,
                            template: item.style,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (item.premium)
              const Positioned(
                left: 8,
                top: 8,
                child: Icon(Icons.diamond, size: 14, color: Color(0xFFB388FF)),
              ),
            Positioned(
              right: 8,
              bottom: 8,
              child: downloading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      installed ? Icons.check_circle : Icons.download,
                      size: 16,
                      color: installed ? Colors.lightGreenAccent : Colors.white54,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
