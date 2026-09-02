/// Visual treatment for overlay text, cycled by the style button in the editor.
enum TextOverlayStyle {
  /// Default text with a soft shadow.
  plain,

  /// Text stroke in the selected color.
  outline,

  /// Solid rectangular background in the selected color.
  box,

  /// Semi-transparent dark background behind the text.
  boxDim;

  TextOverlayStyle get next =>
      TextOverlayStyle.values[(index + 1) % TextOverlayStyle.values.length];

  static TextOverlayStyle fromJson(String? value) {
    if (value == null) return TextOverlayStyle.plain;
    for (final style in TextOverlayStyle.values) {
      if (style.name == value) return style;
    }
    return TextOverlayStyle.plain;
  }
}
