import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/models/transition_item.dart';
import 'package:aveditor/services/transition_catalog_service.dart';
import 'package:flutter/material.dart';

/// Shows the cut-transition picker and returns the chosen item, or null if cancelled.
Future<TransitionItem?> showTransitionPickerSheet(
  BuildContext context, {
  String? selectedId,
}) {
  return showModalBottomSheet<TransitionItem>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      return TransitionPickerSheet(selectedId: selectedId);
    },
  );
}

class TransitionPickerSheet extends StatefulWidget {
  const TransitionPickerSheet({super.key, this.selectedId});

  final String? selectedId;

  @override
  State<TransitionPickerSheet> createState() => _TransitionPickerSheetState();
}

class _TransitionPickerSheetState extends State<TransitionPickerSheet> {
  final _service = TransitionCatalogService.instance;
  var _loading = true;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _service.ensureInitialized();
    if (mounted) setState(() => _loading = false);
  }

  Color _parseAccent(String hex) {
    final cleaned = hex.replaceFirst('#', '');
    if (cleaned.length != 6) return const Color(0xFF6B7280);
    return Color(int.parse('FF$cleaned', radix: 16));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final items = _service.catalog.items;
    final selected = widget.selectedId ?? 'none';

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.transitionSheetTitle,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.transitionSheetSubtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(l10n.transitionCatalogUnavailable),
              )
            else
              SizedBox(
                height: 168,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final isSelected = item.id == selected ||
                        (item.isNone &&
                            (selected.isEmpty || selected == 'none'));
                    final accent = _parseAccent(item.accent);
                    final label = item.isNone ? l10n.transitionNone : item.title;

                    return InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => Navigator.of(context).pop(item),
                      child: SizedBox(
                        width: 96,
                        child: Column(
                          children: [
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 160),
                              height: 96,
                              width: 96,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: accent.withValues(alpha: 0.22),
                                border: Border.all(
                                  color: isSelected
                                      ? theme.colorScheme.primary
                                      : accent.withValues(alpha: 0.55),
                                  width: isSelected ? 2.5 : 1,
                                ),
                              ),
                              child: Icon(
                                item.isNone
                                    ? Icons.block
                                    : Icons.animation_outlined,
                                color: accent,
                                size: 32,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              label,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: isSelected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
