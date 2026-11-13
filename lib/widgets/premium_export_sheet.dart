import 'dart:async';

import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/services/premium_usage.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:share_lib/share_lib.dart';

enum PremiumExportChoice { pro, watchAd, strip }

/// Bottom sheet shown when a free user exports a video that uses Pro items.
Future<PremiumExportChoice?> showPremiumExportSheet(
  BuildContext context,
  List<PremiumUse> uses,
) {
  return showModalBottomSheet<PremiumExportChoice>(
    context: context,
    showDragHandle: true,
    backgroundColor: AppTheme.surface,
    builder: (sheetContext) => _PremiumExportSheet(uses: uses),
  );
}

class _PremiumExportSheet extends StatelessWidget {
  const _PremiumExportSheet({required this.uses});

  final List<PremiumUse> uses;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    void choose(PremiumExportChoice c) => Navigator.of(context).pop(c);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
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
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final use in uses)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: Icon(
                      use.kind == PremiumUseKind.transition
                          ? Icons.auto_awesome_motion
                          : Icons.text_fields,
                      size: 16,
                    ),
                    label: Text(use.title),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => choose(PremiumExportChoice.pro),
              icon: const Icon(Icons.workspace_premium),
              label: Text(l10n.premiumExportWithPro),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => choose(PremiumExportChoice.watchAd),
              icon: const Icon(Icons.play_circle_outline),
              label: Text(l10n.premiumExportWatchAd),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => choose(PremiumExportChoice.strip),
              child: Text(l10n.premiumExportStrip),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows an ad through share_lib's [AdService] and resolves whether this one
/// export is unlocked.
///
/// - Rewarded ad: unlocked only when the reward is earned.
/// - Interstitial-only rotation: unlocked once the ad was shown and closed.
/// - No ad available (no fill, no settings): unlocked, so a missing ad never
///   blocks the user from saving.
Future<bool> watchAdToUnlockExport() {
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
