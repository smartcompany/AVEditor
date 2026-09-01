/// Export quality presets modelled after CapCut's defaults.
///
/// CapCut's out-of-the-box export is roughly 1080p, ~30 fps, medium-high
/// bitrate, and it avoids re-encoding when nothing changed. These profiles
/// mirror that behaviour.
enum ExportQualityProfile {
  /// Default — 1080p cap, no upscale, CRF 20, stream copy when possible.
  recommended,

  /// Best looking encode — CRF 18, slower preset, always re-encodes.
  high,

  /// Smaller files — CRF 28, fast preset, stream copy when possible.
  smaller,

  /// Match the source — stream copy when possible, otherwise a light encode.
  original,
}

extension ExportQualityProfileX on ExportQualityProfile {
  /// Whether trim-only exports can skip re-encoding entirely.
  bool get allowsStreamCopy => switch (this) {
        ExportQualityProfile.recommended ||
        ExportQualityProfile.smaller ||
        ExportQualityProfile.original =>
          true,
        ExportQualityProfile.high => false,
      };

  /// CapCut never upscales sub-1080p footage to fake 1080p.
  bool get allowUpscale => false;

  String? get crf => switch (this) {
        ExportQualityProfile.recommended => '20',
        ExportQualityProfile.high => '18',
        ExportQualityProfile.smaller => '28',
        ExportQualityProfile.original => null,
      };

  String get encodePreset => switch (this) {
        ExportQualityProfile.recommended => 'medium',
        ExportQualityProfile.high => 'slow',
        ExportQualityProfile.smaller => 'fast',
        ExportQualityProfile.original => 'medium',
      };

  /// Used when [original] must encode (overlays, rotation, etc.).
  String get fallbackCrf => '18';
}

/// FFmpeg `scale` filter flags — Lanczos keeps edges sharp without ringing.
const kExportScaleFlags = 'lanczos';
