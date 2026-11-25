import 'package:aveditor/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Shared look for docked editor studios (text, stickers, transitions).
/// Matches [AppTheme] magenta / purple surfaces — not flat cool-gray chrome.
abstract final class EditorDockChrome {
  static const headerHeight = 48.0;

  static BoxDecoration panelDecoration() {
    return BoxDecoration(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
      gradient: const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color(0xFF1A1224),
          AppTheme.surface,
          Color(0xFF120C18),
        ],
        stops: [0.0, 0.35, 1.0],
      ),
      border: Border(
        top: BorderSide(color: AppTheme.muted.withValues(alpha: 0.22)),
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.45),
          blurRadius: 18,
          offset: const Offset(0, -4),
        ),
      ],
    );
  }

  static Widget shell({required Widget child}) {
    return Material(
      color: Colors.transparent,
      elevation: 0,
      child: DecoratedBox(
        decoration: panelDecoration(),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          child: child,
        ),
      ),
    );
  }

  static Widget closeButton({
    required VoidCallback onPressed,
    required String tooltip,
  }) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(
        Icons.close_rounded,
        color: AppTheme.ink.withValues(alpha: 0.72),
      ),
    );
  }

  static Widget progressBar() {
    return const LinearProgressIndicator(
      minHeight: 2,
      backgroundColor: Color(0x22FFFFFF),
      color: AppTheme.accent,
    );
  }

  static Widget loadingSpinner() {
    return const Center(
      child: SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          color: AppTheme.accent,
        ),
      ),
    );
  }
}

/// Underline tab used in text / sticker / transition docks.
class EditorDockTabLabel extends StatelessWidget {
  const EditorDockTabLabel({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: GoogleFonts.dmSans(
                fontSize: 13,
                height: 1.2,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected
                    ? AppTheme.ink
                    : AppTheme.muted.withValues(alpha: 0.9),
              ),
            ),
            const SizedBox(height: 4),
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              height: 2.5,
              width: selected ? 22 : 10,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                gradient: selected ? AppTheme.brandGradientHorizontal : null,
                color: selected ? null : Colors.transparent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Grid tile chrome for catalog / sticker cells.
class EditorDockTile extends StatelessWidget {
  const EditorDockTile({
    super.key,
    required this.selected,
    required this.onTap,
    required this.child,
    this.label,
    this.badge,
  });

  final bool selected;
  final VoidCallback? onTap;
  final Widget child;
  final String? label;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: AppTheme.surfaceElevated.withValues(alpha: 0.92),
            border: Border.all(
              color: selected
                  ? AppTheme.accent.withValues(alpha: 0.85)
                  : AppTheme.muted.withValues(alpha: 0.22),
              width: selected ? 1.6 : 1,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: AppTheme.accent.withValues(alpha: 0.22),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Stack(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(6, 8, 6, label == null ? 6 : 6),
                child: Column(
                  children: [
                    Expanded(child: Center(child: ClipRect(child: child))),
                    if (label != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        label!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: GoogleFonts.dmSans(
                          color: selected
                              ? AppTheme.ink
                              : AppTheme.muted.withValues(alpha: 0.95),
                          fontSize: 10,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (badge != null) Positioned(right: 5, top: 5, child: badge!),
            ],
          ),
        ),
      ),
    );
  }
}
