import 'package:aveditor/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Shared chrome for YouTube / TikTok upload screens — matches [AppTheme].
abstract final class UploadFormChrome {
  static InputDecoration fieldDecoration({
    required String label,
    String? hint,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      filled: true,
      fillColor: AppTheme.surfaceElevated,
      labelStyle: GoogleFonts.dmSans(color: AppTheme.muted, fontSize: 13),
      hintStyle: GoogleFonts.dmSans(
        color: AppTheme.muted.withValues(alpha: 0.7),
        fontSize: 14,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppTheme.muted.withValues(alpha: 0.22)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppTheme.muted.withValues(alpha: 0.22)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppTheme.accent, width: 1.4),
      ),
    );
  }
}

class UploadAmbientScaffold extends StatelessWidget {
  const UploadAmbientScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions,
    this.automaticallyImplyLeading = true,
    this.bottom,
  });

  final String title;
  final Widget body;
  final List<Widget>? actions;
  final bool automaticallyImplyLeading;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        automaticallyImplyLeading: automaticallyImplyLeading,
        title: Text(
          title,
          style: GoogleFonts.spaceGrotesk(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: AppTheme.ink,
          ),
        ),
        actions: actions,
      ),
      body: DecoratedBox(
        decoration: AppTheme.ambientBackgroundDecoration(),
        child: Column(
          children: [
            Expanded(child: body),
            ?bottom,
          ],
        ),
      ),
    );
  }
}

class UploadSectionLabel extends StatelessWidget {
  const UploadSectionLabel(this.text, {super.key, this.help});

  final String text;
  final String? help;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          text,
          style: GoogleFonts.spaceGrotesk(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: AppTheme.ink,
            letterSpacing: 0.2,
          ),
        ),
        if (help != null) ...[
          const SizedBox(height: 4),
          Text(
            help!,
            style: GoogleFonts.dmSans(
              fontSize: 12,
              height: 1.35,
              color: AppTheme.muted,
            ),
          ),
        ],
      ],
    );
  }
}

class UploadSurfaceCard extends StatelessWidget {
  const UploadSurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.muted.withValues(alpha: 0.22)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

class UploadChoiceChips<T> extends StatelessWidget {
  const UploadChoiceChips({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final List<(T value, String label)> options;
  final T? value;
  final ValueChanged<T>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (option, label) in options)
          _Chip(
            label: label,
            selected: value == option,
            enabled: enabled,
            onTap: onChanged == null ? null : () => onChanged!(option),
          ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected
        ? AppTheme.ink
        : enabled
        ? AppTheme.ink.withValues(alpha: 0.85)
        : AppTheme.muted;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: selected ? AppTheme.brandGradientHorizontal : null,
            color: selected ? null : AppTheme.surfaceElevated,
            border: selected
                ? null
                : Border.all(color: AppTheme.muted.withValues(alpha: 0.28)),
          ),
          child: Text(
            label,
            style: GoogleFonts.dmSans(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

class UploadToggleTile extends StatelessWidget {
  const UploadToggleTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.dmSans(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.ink,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: GoogleFonts.dmSans(
                        fontSize: 12,
                        color: AppTheme.muted,
                        height: 1.3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Switch.adaptive(
              value: value,
              onChanged: enabled ? onChanged : null,
              activeThumbColor: AppTheme.ink,
              activeTrackColor: AppTheme.accent,
            ),
          ],
        ),
      ),
    );
  }
}

class UploadGradientButton extends StatelessWidget {
  const UploadGradientButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.busyLabel,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final Widget? busyLabel;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    return Opacity(
      opacity: enabled || busy ? 1 : 0.4,
      child: DecoratedBox(
        decoration: AppTheme.brandGradientDecoration(borderRadius: 14),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled ? onPressed : null,
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: Center(
                child: busy
                    ? (busyLabel ??
                          const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: AppTheme.ink,
                            ),
                          ))
                    : Text(
                        label,
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.ink,
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class UploadCheckBadge extends StatelessWidget {
  const UploadCheckBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 76,
      height: 76,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: AppTheme.brandGradient,
        boxShadow: [
          BoxShadow(
            color: AppTheme.accent.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: const Icon(Icons.check_rounded, size: 42, color: AppTheme.ink),
    );
  }
}
