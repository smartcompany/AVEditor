import 'package:flutter/foundation.dart';

/// Horizontal alignment inside a composition column.
enum TextCompAlign { start, center, end }

/// One editable text field inside a CapCut-like template.
@immutable
class TextCompSlot {
  const TextCompSlot({
    required this.id,
    required this.defaultText,
    this.role,
    this.fontSizeFactor = 1,
    this.fontWeight = 700,
    this.italic = false,
    this.letterSpacingEm = 0,
    this.fillArgb,
    this.preferredFontId,
    this.align = TextCompAlign.center,
    this.dxFactor = 0,
    this.boxFillArgb,
    this.boxPadHFactor = 0.2,
    this.boxPadVFactor = 0.12,
    this.boxStrokeArgb,
    this.boxStrokeWidthFactor = 0,
  });

  final String id;
  final String defaultText;
  final String? role;
  final double fontSizeFactor;
  final int fontWeight;
  final bool italic;
  final double letterSpacingEm;
  final int? fillArgb;
  final String? preferredFontId;
  final TextCompAlign align;
  final double dxFactor;
  final int? boxFillArgb;
  final double boxPadHFactor;
  final double boxPadVFactor;
  final int? boxStrokeArgb;
  final double boxStrokeWidthFactor;

  Map<String, dynamic> toJson() => {
        'id': id,
        'defaultText': defaultText,
        if (role != null) 'role': role,
        'fontSizeFactor': fontSizeFactor,
        'fontWeight': fontWeight,
        if (italic) 'italic': italic,
        if (letterSpacingEm != 0) 'letterSpacingEm': letterSpacingEm,
        if (fillArgb != null) 'fillColor': fillArgb,
        if (preferredFontId != null) 'preferredFontId': preferredFontId,
        'align': align.name,
        if (dxFactor != 0) 'dxFactor': dxFactor,
        if (boxFillArgb != null) 'boxFillColor': boxFillArgb,
        'boxPadHFactor': boxPadHFactor,
        'boxPadVFactor': boxPadVFactor,
        if (boxStrokeArgb != null) 'boxStrokeColor': boxStrokeArgb,
        if (boxStrokeWidthFactor != 0)
          'boxStrokeWidthFactor': boxStrokeWidthFactor,
      };

  factory TextCompSlot.fromJson(Map<String, dynamic> json) {
    return TextCompSlot(
      id: json['id'] as String? ?? 'slot',
      defaultText: json['defaultText'] as String? ?? '',
      role: json['role'] as String?,
      fontSizeFactor: (json['fontSizeFactor'] as num?)?.toDouble() ?? 1,
      fontWeight: (json['fontWeight'] as num?)?.toInt() ?? 700,
      italic: json['italic'] as bool? ?? false,
      letterSpacingEm: (json['letterSpacingEm'] as num?)?.toDouble() ?? 0,
      fillArgb: json['fillColor'] as int?,
      preferredFontId: json['preferredFontId'] as String?,
      align: _alignFrom(json['align'] as String?),
      dxFactor: (json['dxFactor'] as num?)?.toDouble() ?? 0,
      boxFillArgb: json['boxFillColor'] as int?,
      boxPadHFactor: (json['boxPadHFactor'] as num?)?.toDouble() ?? 0.2,
      boxPadVFactor: (json['boxPadVFactor'] as num?)?.toDouble() ?? 0.12,
      boxStrokeArgb: json['boxStrokeColor'] as int?,
      boxStrokeWidthFactor:
          (json['boxStrokeWidthFactor'] as num?)?.toDouble() ?? 0,
    );
  }
}

enum TextCompDecorationKind { barV, barH, rule, slash, chevronDown }

@immutable
class TextCompDecoration {
  const TextCompDecoration({
    required this.id,
    required this.kind,
    this.colorArgb,
    this.opacity = 1,
    this.slotId,
    this.attach,
    this.thicknessFactor = 0.08,
    this.lengthFactor = 1,
    this.gapFactor = 0.15,
    this.widthFactor = 0.8,
    this.heightFactor = 0.5,
  });

  final String id;
  final TextCompDecorationKind kind;
  final int? colorArgb;
  final double opacity;
  final String? slotId;
  final String? attach;
  final double thicknessFactor;
  final double lengthFactor;
  final double gapFactor;
  final double widthFactor;
  final double heightFactor;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': _kindToJson(kind),
        if (colorArgb != null) 'color': colorArgb,
        'opacity': opacity,
        if (slotId != null) 'slotId': slotId,
        if (attach != null) 'attach': attach,
        'thicknessFactor': thicknessFactor,
        'lengthFactor': lengthFactor,
        'gapFactor': gapFactor,
        'widthFactor': widthFactor,
        'heightFactor': heightFactor,
      };

  factory TextCompDecoration.fromJson(Map<String, dynamic> json) {
    return TextCompDecoration(
      id: json['id'] as String? ?? 'decor',
      kind: _kindFrom(json['kind'] as String?),
      colorArgb: json['color'] as int?,
      opacity: (json['opacity'] as num?)?.toDouble() ?? 1,
      slotId: json['slotId'] as String?,
      attach: json['attach'] as String?,
      thicknessFactor: (json['thicknessFactor'] as num?)?.toDouble() ?? 0.08,
      lengthFactor: (json['lengthFactor'] as num?)?.toDouble() ?? 1,
      gapFactor: (json['gapFactor'] as num?)?.toDouble() ?? 0.15,
      widthFactor: (json['widthFactor'] as num?)?.toDouble() ?? 0.8,
      heightFactor: (json['heightFactor'] as num?)?.toDouble() ?? 0.5,
    );
  }
}

/// One painted row: style slot + body line.
@immutable
class TextCompEntry {
  const TextCompEntry({required this.slot, required this.text});

  final TextCompSlot slot;
  final String text;
}

/// Declarative multi-slot template layout (server-driven).
@immutable
class TextComposition {
  const TextComposition({
    required this.slots,
    this.align = TextCompAlign.center,
    this.gapFactor = 0.16,
    this.decorations = const [],
    this.repeatSlots = false,
  });

  final TextCompAlign align;
  final double gapFactor;
  final List<TextCompSlot> slots;
  final List<TextCompDecoration> decorations;

  /// When true (e.g. Chat Message), each newline is a new bubble and styles
  /// cycle through [slots]. When false, extra lines fold into the last slot.
  final bool repeatSlots;

  String get sampleText => slots.map((s) => s.defaultText).join('\n');

  List<String> _linesOf(String overlayText) =>
      overlayText.replaceAll('\r\n', '\n').split('\n');

  /// How many bubbles / rows to paint for [overlayText].
  int paintedSlotCount(String overlayText) {
    if (slots.isEmpty) return 0;
    if (!repeatSlots) return slots.length;
    return _linesOf(overlayText).length.clamp(1, 999);
  }

  /// Split overlay body into per-slot strings.
  ///
  /// Default: extra lines fold into the last slot.
  /// [repeatSlots]: one string per line (styles applied via [entriesFor]).
  List<String> textsFor(String overlayText) {
    final n = slots.length;
    if (n <= 0) return const [];
    final lines = _linesOf(overlayText);
    if (repeatSlots) {
      return lines.isEmpty ? const [''] : lines;
    }
    if (n == 1) return [lines.join('\n')];
    return [
      for (var i = 0; i < n; i++)
        if (i < n - 1) (i < lines.length ? lines[i] : '')
        else lines.skip(i).join('\n'),
    ];
  }

  /// Style + text pairs actually painted (expands when [repeatSlots]).
  List<TextCompEntry> entriesFor(String overlayText) {
    if (slots.isEmpty) return const [];
    if (!repeatSlots) {
      final texts = textsFor(overlayText);
      return [
        for (var i = 0; i < slots.length; i++)
          TextCompEntry(
            slot: slots[i],
            text: i < texts.length ? texts[i] : '',
          ),
      ];
    }
    final lines = _linesOf(overlayText);
    final rows = lines.isEmpty ? const [''] : lines;
    return [
      for (var i = 0; i < rows.length; i++)
        TextCompEntry(slot: slots[i % slots.length], text: rows[i]),
    ];
  }

  Map<String, dynamic> toJson() => {
        'align': align.name,
        'gapFactor': gapFactor,
        if (repeatSlots) 'repeatSlots': true,
        'slots': slots.map((s) => s.toJson()).toList(),
        if (decorations.isNotEmpty)
          'decorations': decorations.map((d) => d.toJson()).toList(),
      };

  factory TextComposition.fromJson(Map<String, dynamic> json) {
    return TextComposition(
      align: _alignFrom(json['align'] as String?),
      gapFactor: (json['gapFactor'] as num?)?.toDouble() ?? 0.16,
      repeatSlots: json['repeatSlots'] as bool? ?? false,
      slots: (json['slots'] as List<dynamic>? ?? const [])
          .map((e) => TextCompSlot.fromJson(e as Map<String, dynamic>))
          .toList(),
      decorations: (json['decorations'] as List<dynamic>? ?? const [])
          .map((e) => TextCompDecoration.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

TextCompAlign _alignFrom(String? raw) {
  return switch (raw) {
    'start' => TextCompAlign.start,
    'end' => TextCompAlign.end,
    _ => TextCompAlign.center,
  };
}

TextCompDecorationKind _kindFrom(String? raw) {
  return switch (raw) {
    'bar_v' => TextCompDecorationKind.barV,
    'bar_h' => TextCompDecorationKind.barH,
    'rule' => TextCompDecorationKind.rule,
    'slash' => TextCompDecorationKind.slash,
    'chevron_down' => TextCompDecorationKind.chevronDown,
    _ => TextCompDecorationKind.rule,
  };
}

String _kindToJson(TextCompDecorationKind kind) {
  return switch (kind) {
    TextCompDecorationKind.barV => 'bar_v',
    TextCompDecorationKind.barH => 'bar_h',
    TextCompDecorationKind.rule => 'rule',
    TextCompDecorationKind.slash => 'slash',
    TextCompDecorationKind.chevronDown => 'chevron_down',
  };
}
