import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Visual language aligned with the app icon:
/// near-black magenta base + orange → magenta → purple → cyan gradient.
abstract final class AppTheme {
  static const background = Color(0xFF0B0610);
  static const surface = Color(0xFF16101C);
  static const surfaceElevated = Color(0xFF1E1628);
  static const ink = Color(0xFFF4F1EA);
  static const muted = Color(0xFFA89BB0);

  /// Primary CTA / selection / cursor (icon center magenta).
  static const accent = Color(0xFFE835C1);

  /// Selected tools, cyan end of brand gradient.
  static const accentCyan = Color(0xFF5B9DFF);

  /// Secondary chips / waveform peaks (warm end of brand gradient).
  static const accentWarm = Color(0xFFFF8A3D);

  static const gradientOrange = Color(0xFFFF8A3D);
  static const gradientMagenta = Color(0xFFE835C1);
  static const gradientPurple = Color(0xFF9B4DFF);
  static const gradientCyan = Color(0xFF4CC9F0);

  static const brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      gradientOrange,
      gradientMagenta,
      gradientPurple,
      gradientCyan,
    ],
    stops: [0.0, 0.35, 0.65, 1.0],
  );

  static const brandGradientHorizontal = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [
      gradientOrange,
      gradientMagenta,
      gradientPurple,
      gradientCyan,
    ],
    stops: [0.0, 0.35, 0.65, 1.0],
  );

  static BoxDecoration brandGradientDecoration({
    double borderRadius = 12,
    double opacity = 1,
  }) {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      gradient: LinearGradient(
        begin: brandGradient.begin,
        end: brandGradient.end,
        colors: brandGradient.colors
            .map((c) => c.withValues(alpha: opacity))
            .toList(growable: false),
        stops: brandGradient.stops,
      ),
    );
  }

  /// Soft ambient wash for scaffold bodies (home, etc.).
  static BoxDecoration ambientBackgroundDecoration() {
    return const BoxDecoration(
      color: background,
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFF1A0A18),
          background,
          Color(0xFF0A1020),
        ],
        stops: [0.0, 0.45, 1.0],
      ),
    );
  }

  static ThemeData dark() {
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: Brightness.dark,
        surface: surface,
        primary: accent,
        secondary: accentCyan,
        tertiary: accentWarm,
      ),
      scaffoldBackgroundColor: background,
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: muted.withValues(alpha: 0.22)),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: ink,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: GoogleFonts.spaceGrotesk(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: ink,
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: accent,
        linearTrackColor: Color(0x33FFFFFF),
      ),
      textTheme: TextTheme(
        bodyMedium: GoogleFonts.dmSans(color: ink),
        bodySmall: GoogleFonts.dmSans(color: muted),
        titleLarge: GoogleFonts.spaceGrotesk(
          color: ink,
          fontWeight: FontWeight.w700,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: ink,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          side: BorderSide(color: accent.withValues(alpha: 0.35)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
    return base;
  }
}
