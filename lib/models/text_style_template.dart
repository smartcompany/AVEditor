import 'package:flutter/material.dart';

/// One outline pass around the glyphs. Width scales with font size.
@immutable
class TextStyleStroke {
  const TextStyleStroke({
    required this.widthFactor,
    this.useAccent = true,
    this.colorArgb,
  });

  /// Stroke width as a fraction of [fontSize].
  final double widthFactor;
  final bool useAccent;
  final int? colorArgb;

  Color resolveColor(Color accent) {
    if (useAccent) return accent;
    return Color(colorArgb ?? 0xFFFFFFFF);
  }

  Map<String, dynamic> toJson() => {
    'widthFactor': widthFactor,
    'useAccent': useAccent,
    if (colorArgb != null) 'color': colorArgb,
  };

  factory TextStyleStroke.fromJson(Map<String, dynamic> json) {
    return TextStyleStroke(
      widthFactor: (json['widthFactor'] as num).toDouble(),
      useAccent: json['useAccent'] as bool? ?? true,
      colorArgb: json['color'] as int?,
    );
  }
}

/// Soft outer glow painted behind the text.
@immutable
class TextStyleGlow {
  const TextStyleGlow({
    required this.blurFactor,
    this.widthFactor = 0.12,
    this.useAccent = true,
    this.colorArgb,
    this.opacity = 0.85,
  });

  final double blurFactor;
  final double widthFactor;
  final bool useAccent;
  final int? colorArgb;
  final double opacity;

  Color resolveColor(Color accent) {
    final base = useAccent ? accent : Color(colorArgb ?? 0xFFFF4D4D);
    return base.withValues(alpha: opacity.clamp(0.0, 1.0));
  }

  Map<String, dynamic> toJson() => {
    'blurFactor': blurFactor,
    'widthFactor': widthFactor,
    'useAccent': useAccent,
    'opacity': opacity,
    if (colorArgb != null) 'color': colorArgb,
  };

  factory TextStyleGlow.fromJson(Map<String, dynamic> json) {
    return TextStyleGlow(
      blurFactor: (json['blurFactor'] as num).toDouble(),
      widthFactor: (json['widthFactor'] as num?)?.toDouble() ?? 0.12,
      useAccent: json['useAccent'] as bool? ?? true,
      colorArgb: json['color'] as int?,
      opacity: (json['opacity'] as num?)?.toDouble() ?? 0.85,
    );
  }
}

/// Hard or soft drop shadow behind the fill.
@immutable
class TextStyleShadow {
  const TextStyleShadow({
    required this.dxFactor,
    required this.dyFactor,
    this.blurFactor = 0,
    this.useAccent = false,
    this.colorArgb = 0xFF000000,
    this.opacity = 0.7,
  });

  final double dxFactor;
  final double dyFactor;
  final double blurFactor;
  final bool useAccent;
  final int? colorArgb;
  final double opacity;

  Color resolveColor(Color accent) {
    final base = useAccent ? accent : Color(colorArgb ?? 0xFF000000);
    return base.withValues(alpha: opacity.clamp(0.0, 1.0));
  }

  Map<String, dynamic> toJson() => {
    'dxFactor': dxFactor,
    'dyFactor': dyFactor,
    'blurFactor': blurFactor,
    'useAccent': useAccent,
    'opacity': opacity,
    if (colorArgb != null) 'color': colorArgb,
  };

  factory TextStyleShadow.fromJson(Map<String, dynamic> json) {
    return TextStyleShadow(
      dxFactor: (json['dxFactor'] as num).toDouble(),
      dyFactor: (json['dyFactor'] as num).toDouble(),
      blurFactor: (json['blurFactor'] as num?)?.toDouble() ?? 0,
      useAccent: json['useAccent'] as bool? ?? false,
      colorArgb: json['color'] as int?,
      opacity: (json['opacity'] as num?)?.toDouble() ?? 0.7,
    );
  }
}

/// Per-line rounded background behind the glyphs.
@immutable
class TextStyleLineBackground {
  const TextStyleLineBackground({
    this.useAccent = true,
    this.colorArgb,
    this.opacity = 1,
    this.padHFactor = 0.22,
    this.padVFactor = 0.14,
    this.radiusFactor = 0.18,
  });

  final bool useAccent;
  final int? colorArgb;
  final double opacity;
  final double padHFactor;
  final double padVFactor;
  final double radiusFactor;

  Color resolveColor(Color accent) {
    final base = useAccent ? accent : Color(colorArgb ?? 0xFF000000);
    return base.withValues(alpha: opacity.clamp(0.0, 1.0));
  }

  Map<String, dynamic> toJson() => {
    'useAccent': useAccent,
    'opacity': opacity,
    'padHFactor': padHFactor,
    'padVFactor': padVFactor,
    'radiusFactor': radiusFactor,
    if (colorArgb != null) 'color': colorArgb,
  };

  factory TextStyleLineBackground.fromJson(Map<String, dynamic> json) {
    return TextStyleLineBackground(
      useAccent: json['useAccent'] as bool? ?? true,
      colorArgb: json['color'] as int?,
      opacity: (json['opacity'] as num?)?.toDouble() ?? 1,
      padHFactor: (json['padHFactor'] as num?)?.toDouble() ?? 0.22,
      padVFactor: (json['padVFactor'] as num?)?.toDouble() ?? 0.14,
      radiusFactor: (json['radiusFactor'] as num?)?.toDouble() ?? 0.18,
    );
  }
}

/// Declarative Word Art look. Stored as JSON so packs can ship later.
@immutable
class TextStyleTemplate {
  const TextStyleTemplate({
    required this.id,
    required this.label,
    this.fillUseAccent = true,
    this.fillArgb,
    this.fillContrastOnAccent = false,
    this.strokes = const [],
    this.glow,
    this.shadow,
    this.lineBackground,
  });

  final String id;

  /// Short UI label (English). Localized titles can map from [id] later.
  final String label;
  final bool fillUseAccent;
  final int? fillArgb;

  /// When true, fill is black/white based on accent luminance.
  final bool fillContrastOnAccent;
  final List<TextStyleStroke> strokes;
  final TextStyleGlow? glow;
  final TextStyleShadow? shadow;
  final TextStyleLineBackground? lineBackground;

  Color resolveFill(Color accent) {
    if (fillContrastOnAccent) {
      return accent.computeLuminance() > 0.55 ? Colors.black : Colors.white;
    }
    if (fillUseAccent) return accent;
    return Color(fillArgb ?? 0xFFFFFFFF);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'fillUseAccent': fillUseAccent,
    'fillContrastOnAccent': fillContrastOnAccent,
    if (fillArgb != null) 'fillColor': fillArgb,
    'strokes': strokes.map((s) => s.toJson()).toList(),
    if (glow != null) 'glow': glow!.toJson(),
    if (shadow != null) 'shadow': shadow!.toJson(),
    if (lineBackground != null) 'lineBackground': lineBackground!.toJson(),
  };

  factory TextStyleTemplate.fromJson(Map<String, dynamic> json) {
    return TextStyleTemplate(
      id: json['id'] as String,
      label: json['label'] as String? ?? json['id'] as String,
      fillUseAccent: json['fillUseAccent'] as bool? ?? true,
      fillArgb: json['fillColor'] as int?,
      fillContrastOnAccent: json['fillContrastOnAccent'] as bool? ?? false,
      strokes: (json['strokes'] as List<dynamic>? ?? const [])
          .map((e) => TextStyleStroke.fromJson(e as Map<String, dynamic>))
          .toList(),
      glow: json['glow'] == null
          ? null
          : TextStyleGlow.fromJson(json['glow'] as Map<String, dynamic>),
      shadow: json['shadow'] == null
          ? null
          : TextStyleShadow.fromJson(json['shadow'] as Map<String, dynamic>),
      lineBackground: json['lineBackground'] == null
          ? null
          : TextStyleLineBackground.fromJson(
              json['lineBackground'] as Map<String, dynamic>,
            ),
    );
  }
}

/// Built-in Word Art presets shipped with the app.
class TextStyleTemplateCatalog {
  TextStyleTemplateCatalog._();

  static const classic = TextStyleTemplate(
    id: 'classic',
    label: 'Classic',
    fillUseAccent: true,
    shadow: TextStyleShadow(
      dxFactor: 0,
      dyFactor: 0.04,
      blurFactor: 0.12,
      colorArgb: 0xFF000000,
      opacity: 0.55,
    ),
  );

  static const outline = TextStyleTemplate(
    id: 'outline',
    label: 'Outline',
    fillContrastOnAccent: true,
    strokes: [
      TextStyleStroke(widthFactor: 0.1, useAccent: true),
    ],
  );

  static const neon = TextStyleTemplate(
    id: 'neon',
    label: 'Neon',
    fillUseAccent: true,
    strokes: [
      TextStyleStroke(widthFactor: 0.14, useAccent: true),
    ],
    glow: TextStyleGlow(
      blurFactor: 0.45,
      widthFactor: 0.18,
      useAccent: true,
      opacity: 0.9,
    ),
  );

  static const comic = TextStyleTemplate(
    id: 'comic',
    label: 'Comic',
    fillArgb: 0xFFFFFFF0,
    fillUseAccent: false,
    strokes: [
      TextStyleStroke(
        widthFactor: 0.16,
        useAccent: false,
        colorArgb: 0xFF1A1028,
      ),
    ],
    shadow: TextStyleShadow(
      dxFactor: 0.08,
      dyFactor: 0.1,
      blurFactor: 0,
      useAccent: true,
      opacity: 1,
    ),
  );

  static const softGlow = TextStyleTemplate(
    id: 'soft_glow',
    label: 'Glow',
    fillUseAccent: true,
    glow: TextStyleGlow(
      blurFactor: 0.55,
      widthFactor: 0.2,
      useAccent: true,
      opacity: 0.75,
    ),
    shadow: TextStyleShadow(
      dxFactor: 0,
      dyFactor: 0.03,
      blurFactor: 0.1,
      colorArgb: 0xFF000000,
      opacity: 0.35,
    ),
  );

  static const banner = TextStyleTemplate(
    id: 'banner',
    label: 'Banner',
    fillContrastOnAccent: true,
    lineBackground: TextStyleLineBackground(
      useAccent: true,
      opacity: 1,
      padHFactor: 0.28,
      padVFactor: 0.16,
      radiusFactor: 0.2,
    ),
  );

  static const dimBanner = TextStyleTemplate(
    id: 'dim_banner',
    label: 'Dim',
    fillArgb: 0xFFFFFFFF,
    fillUseAccent: false,
    lineBackground: TextStyleLineBackground(
      useAccent: false,
      colorArgb: 0xFF000000,
      opacity: 0.55,
      padHFactor: 0.28,
      padVFactor: 0.16,
      radiusFactor: 0.2,
    ),
  );

  static const pop = TextStyleTemplate(
    id: 'pop',
    label: 'Pop',
    fillUseAccent: true,
    strokes: [
      TextStyleStroke(
        widthFactor: 0.2,
        useAccent: false,
        colorArgb: 0xFFFFFFFF,
      ),
      TextStyleStroke(
        widthFactor: 0.1,
        useAccent: false,
        colorArgb: 0xFF111111,
      ),
    ],
  );

  static const List<TextStyleTemplate> all = [
    classic,
    outline,
    neon,
    comic,
    softGlow,
    banner,
    dimBanner,
    pop,
  ];

  static TextStyleTemplate? byId(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final template in all) {
      if (template.id == id) return template;
    }
    return null;
  }
}
