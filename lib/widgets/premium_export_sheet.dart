import 'dart:async';

import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/services/effect_ad_unlock_service.dart';
import 'package:aveditor/services/premium_usage.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:share_lib/share_lib.dart';

enum PremiumExportChoice { subscribe, strip, continueWithUnlocks }

/// Bottom sheet when export uses effects above the user's plan.
///
/// Per-effect: watch an ad to unlock. Or subscribe for the whole tier.
/// Effects never cost credits.
Future<PremiumExportChoice?> showPremiumExportSheet(
  BuildContext context, {
  required List<PremiumUse> uses,
}) {
  return showModalBottomSheet<PremiumExportChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppTheme.surface,
    builder: (sheetContext) => _PremiumExportSheet(uses: uses),
  );
}

class _PremiumExportSheet extends StatefulWidget {
  const _PremiumExportSheet({required this.uses});

  final List<PremiumUse> uses;

  @override
  State<_PremiumExportSheet> createState() => _PremiumExportSheetState();
}

class _PremiumExportSheetState extends State<_PremiumExportSheet> {
  final _unlocks = EffectAdUnlockService.instance;
  String? _busyKey;

  @override
  void initState() {
    super.initState();
    _unlocks.addListener(_onUnlocksChanged);
  }

  @override
  void dispose() {
    _unlocks.removeListener(_onUnlocksChanged);
    super.dispose();
  }

  void _onUnlocksChanged() {
    if (mounted) setState(() {});
  }

  bool _isUnlocked(PremiumUse use) => _unlocks.isUnlocked(use);

  bool get _allUnlocked => widget.uses.every(_isUnlocked);

  Future<void> _watchAdFor(PremiumUse use) async {
    if (_busyKey != null) return;
    final key = EffectAdUnlockService.keyFor(use);
    setState(() => _busyKey = key);
    final ok = await watchAdToUnlockEffect();
    if (!mounted) return;
    if (!ok) {
      setState(() => _busyKey = null);
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.showSnackBar(
        SnackBar(content: Text(context.l10n.premiumAdNotFinished)),
      );
      return;
    }
    await _unlocks.unlock(use);
    if (!mounted) return;
    setState(() => _busyKey = null);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final bottom = MediaQuery.paddingOf(context).bottom;
    void choose(PremiumExportChoice c) => Navigator.of(context).pop(c);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 12 + bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.workspace_premium, color: AppTheme.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.premiumExportTitle,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              l10n.premiumExportBody,
              style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.muted),
            ),
            const SizedBox(height: 14),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.38,
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: widget.uses.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final use = widget.uses[index];
                  final unlocked = _isUnlocked(use);
                  final key = EffectAdUnlockService.keyFor(use);
                  final busy = _busyKey == key;
                  return _EffectUnlockRow(
                    use: use,
                    unlocked: unlocked,
                    busy: busy,
                    enabled: _busyKey == null && !unlocked,
                    watchLabel: l10n.premiumExportWatchAd,
                    unlockedLabel: l10n.premiumExportEffectUnlocked,
                    onWatch: () => _watchAdFor(use),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busyKey == null
                  ? () => choose(PremiumExportChoice.subscribe)
                  : null,
              icon: const Icon(Icons.workspace_premium),
              label: Text(l10n.premiumExportWithPro),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
            if (_allUnlocked) ...[
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: _busyKey == null
                    ? () => choose(PremiumExportChoice.continueWithUnlocks)
                    : null,
                icon: const Icon(Icons.check_circle_outline),
                label: Text(l10n.premiumExportContinue),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ],
            const SizedBox(height: 4),
            TextButton(
              onPressed: _busyKey == null
                  ? () => choose(PremiumExportChoice.strip)
                  : null,
              child: Text(l10n.premiumExportStrip),
            ),
          ],
        ),
      ),
    );
  }
}

class _EffectUnlockRow extends StatelessWidget {
  const _EffectUnlockRow({
    required this.use,
    required this.unlocked,
    required this.busy,
    required this.enabled,
    required this.watchLabel,
    required this.unlockedLabel,
    required this.onWatch,
  });

  final PremiumUse use;
  final bool unlocked;
  final bool busy;
  final bool enabled;
  final String watchLabel;
  final String unlockedLabel;
  final VoidCallback onWatch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tier = use.accessTier.badgeLabel;
    final isPro = use.accessTier.name == 'pro';

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: AppTheme.surfaceElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: unlocked
              ? AppTheme.accent.withValues(alpha: 0.45)
              : Colors.white10,
        ),
      ),
      child: Row(
        children: [
          Icon(
            use.kind == PremiumUseKind.transition
                ? Icons.auto_awesome_motion
                : Icons.text_fields,
            size: 20,
            color: unlocked ? AppTheme.accent : AppTheme.muted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  use.title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (tier.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    tier,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: isPro
                          ? const Color(0xFFB388FF)
                          : const Color(0xFF60A5FA),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (unlocked)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.check_circle, size: 16, color: AppTheme.accent),
                const SizedBox(width: 4),
                Text(
                  unlockedLabel,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: AppTheme.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            )
          else
            OutlinedButton.icon(
              onPressed: enabled ? onWatch : null,
              icon: busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_circle_outline, size: 18),
              label: Text(watchLabel),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
            ),
        ],
      ),
    );
  }
}

/// Shows an ad through share_lib's [AdService] to unlock one effect.
///
/// - Rewarded: unlocked only when the reward is earned.
/// - Interstitial-only: unlocked once shown and closed.
/// - No ad available: unlocked so a missing ad never hard-blocks.
Future<bool> watchAdToUnlockEffect() {
  final completer = Completer<bool>();
  var shown = false;
  var earned = false;
  void finish(bool value) {
    if (!completer.isCompleted) completer.complete(value);
  }

  unawaited(
    AdService.shared.showAd(
      onAdShown: () => shown = true,
      onUserEarnedReward: (_) => earned = true,
      onAdDismissed: () {
        if (!shown) {
          finish(true);
        } else {
          final rewardedConfigured =
              AdService.shared.rewardedAdId?.isNotEmpty ?? false;
          finish(earned || !rewardedConfigured);
        }
      },
      onAdFailedToShow: () => finish(true),
    ),
  );
  return completer.future;
}
