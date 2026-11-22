import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/utils/av_editor_log.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Shows a brand-styled [SnackBar] and mirrors the text to the debug console
/// so failures are easy to copy from Xcode / `flutter run` logs.
void showLoggedSnackBar(
  BuildContext context,
  String message, {
  Object? error,
  StackTrace? stackTrace,
  Duration duration = const Duration(seconds: 4),
}) {
  final buf = StringBuffer('SNACK $message');
  if (error != null) {
    buf.write(' | $error');
  }
  avEditorLog(buf.toString());
  if (stackTrace != null) {
    debugPrint(stackTrace.toString());
  }

  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(buildAppSnackBar(message, duration: duration));
}

/// Floating toast aligned with Concept A (ambient cards / brand edge).
SnackBar buildAppSnackBar(
  String message, {
  Duration duration = const Duration(seconds: 4),
}) {
  return SnackBar(
    duration: duration,
    behavior: SnackBarBehavior.floating,
    elevation: 0,
    backgroundColor: Colors.transparent,
    padding: EdgeInsets.zero,
    margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    content: DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: AppTheme.brandGradientHorizontal,
        boxShadow: [
          BoxShadow(
            color: AppTheme.accent.withValues(alpha: 0.22),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(1.2),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14.8),
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF2A1B3D), Color(0xFF171022)],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: AppTheme.brandGradientDecoration(borderRadius: 9),
                  child: const Icon(
                    Icons.info_outline_rounded,
                    size: 16,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    message,
                    style: GoogleFonts.dmSans(
                      color: AppTheme.ink,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
