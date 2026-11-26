import 'package:aveditor/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Asks for an App Store / Play review after a successful export share screen.
///
/// Eligibility: installed ≥ [minInstallDays] **or** ≥ [minExportSuccesses]
/// completed exports. At most one prompt every [cooldown], including when the
/// user declines the soft “enjoying?” dialog.
class ReviewPromptService {
  ReviewPromptService._();

  static final ReviewPromptService instance = ReviewPromptService._();

  static const minInstallDays = 2;
  static const minExportSuccesses = 3;
  static const cooldown = Duration(days: 90);

  static const _firstOpenMsKey = 'review_first_open_ms';
  static const _exportSuccessCountKey = 'review_export_success_count';
  static const _lastPromptMsKey = 'review_last_prompt_ms';

  final InAppReview _review = InAppReview.instance;

  /// Call once when the post-export share UI is ready (not album re-share).
  Future<void> recordExportSuccess() async {
    final prefs = await SharedPreferences.getInstance();
    await _ensureFirstOpen(prefs);
    final next = (prefs.getInt(_exportSuccessCountKey) ?? 0) + 1;
    await prefs.setInt(_exportSuccessCountKey, next);
  }

  /// Soft prompt → native review when eligible. Safe to call often.
  Future<void> maybeAsk(
    BuildContext context, {
    required String title,
    required String body,
    required String positiveLabel,
    required String negativeLabel,
  }) async {
    if (!await _isEligible()) return;
    if (!context.mounted) return;

    final liked = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: AppTheme.surfaceElevated,
          title: Text(
            title,
            style: GoogleFonts.spaceGrotesk(
              fontWeight: FontWeight.w700,
              color: AppTheme.ink,
            ),
          ),
          content: Text(
            body,
            style: GoogleFonts.dmSans(color: AppTheme.muted, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(
                negativeLabel,
                style: GoogleFonts.dmSans(color: AppTheme.muted),
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: FilledButton.styleFrom(backgroundColor: AppTheme.accent),
              child: Text(
                positiveLabel,
                style: GoogleFonts.dmSans(
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        );
      },
    );

    // Dismiss, No, or Yes all consume the cooldown so we do not nag.
    await _markPrompted();

    if (liked != true) {
      debugPrint('[ReviewPrompt] soft decline / dismiss');
      return;
    }

    try {
      if (await _review.isAvailable()) {
        await _review.requestReview();
        debugPrint('[ReviewPrompt] requestReview called');
      } else {
        debugPrint('[ReviewPrompt] in-app review unavailable');
      }
    } catch (error, stack) {
      debugPrint('[ReviewPrompt] requestReview failed: $error\n$stack');
    }
  }

  Future<bool> _isEligible() async {
    final prefs = await SharedPreferences.getInstance();
    await _ensureFirstOpen(prefs);

    final lastPrompt = prefs.getInt(_lastPromptMsKey);
    if (lastPrompt != null) {
      final elapsed = DateTime.now().millisecondsSinceEpoch - lastPrompt;
      if (elapsed < cooldown.inMilliseconds) {
        debugPrint('[ReviewPrompt] cooldown active');
        return false;
      }
    }

    final firstOpen = prefs.getInt(_firstOpenMsKey) ?? 0;
    final days = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(firstOpen))
        .inDays;
    final exports = prefs.getInt(_exportSuccessCountKey) ?? 0;
    final ready = days >= minInstallDays || exports >= minExportSuccesses;
    if (!ready) {
      debugPrint(
        '[ReviewPrompt] not ready days=$days exports=$exports '
        '(need days≥$minInstallDays or exports≥$minExportSuccesses)',
      );
    }
    return ready;
  }

  Future<void> _ensureFirstOpen(SharedPreferences prefs) async {
    if (prefs.getInt(_firstOpenMsKey) != null) return;
    await prefs.setInt(
      _firstOpenMsKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _markPrompted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _lastPromptMsKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }
}
