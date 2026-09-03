// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'AVEditor';

  @override
  String get homeTagline => 'Text on your timeline — upload Shorts in one app.';

  @override
  String get pickFromGallery => 'Choose from gallery';

  @override
  String get pickFromFiles => 'Choose video file';

  @override
  String get recordVideo => 'Record video';

  @override
  String get youtubeSignIn => 'Sign in with YouTube';

  @override
  String get youtubeSignedIn => 'YouTube connected';

  @override
  String get youtubeSignOut => 'Sign out';

  @override
  String get editorTitle => 'Edit';

  @override
  String get addText => 'Add text';

  @override
  String get rotateVideo => 'Rotate video';

  @override
  String get export => 'Export';

  @override
  String get uploadShorts => 'Upload Shorts';

  @override
  String get saveToGallery => 'Save to gallery';

  @override
  String get cancel => 'Cancel';

  @override
  String get videoNotSelected => 'No video selected.';

  @override
  String videoPickError(String message) {
    return 'Could not open video: $message';
  }

  @override
  String get permissionPhotosDenied =>
      'Photo library access is off. Enable it in Settings.';

  @override
  String get permissionCameraDenied =>
      'Camera access is off. Enable it in Settings.';

  @override
  String get openSettings => 'Settings';

  @override
  String get comingSoon => 'Coming soon';

  @override
  String get trimStart => 'Trim start';

  @override
  String get trimEnd => 'Trim end';

  @override
  String get textOverlayHint => 'Enter text';

  @override
  String get uploadTitleHint => 'Short title';

  @override
  String get uploadDescriptionHint => 'Description (#Shorts recommended)';

  @override
  String get privacyPublic => 'Public';

  @override
  String get privacyUnlisted => 'Unlisted';

  @override
  String get privacyPrivate => 'Private';

  @override
  String get videoLoadError => 'Could not load video.';

  @override
  String get editText => 'Edit text';

  @override
  String get deleteText => 'Delete';

  @override
  String get fontSize => 'Size';

  @override
  String get textColor => 'Color';

  @override
  String get textStyle => 'Style';

  @override
  String get textStyleCycle => 'Cycle text style';

  @override
  String get textTemplates => 'Word Art';

  @override
  String get textTemplatePacks => 'Packs';

  @override
  String get textPackSection => 'Text template server';

  @override
  String get textPackUrlLabel => 'Pack base URL';

  @override
  String get textPackUrlBody =>
      'Vercel URL for Word Art packs (catalog.json + Lottie). Leave empty to use bundled packs only.';

  @override
  String get textPackUrlSaved => 'Pack server updated.';

  @override
  String get textPackUrlSavePartial =>
      'Saved, but remote catalog could not be reached. Bundled packs still work.';

  @override
  String get timelineClip => 'Clip';

  @override
  String get timelineText => 'Text tracks';

  @override
  String get selectedText => 'Selected text';

  @override
  String get noTextSelected => 'Tap a text bar to edit timing';

  @override
  String durationTotal(String duration) {
    return 'Total $duration';
  }

  @override
  String trimmedDuration(String duration) {
    return 'Clip $duration';
  }

  @override
  String get save => 'Save';

  @override
  String get exporting => 'Exporting video…';

  @override
  String get exportSuccess => 'Saved to your library.';

  @override
  String get exportFailed => 'Export failed.';

  @override
  String exportFailedWithMessage(String message) {
    return 'Export failed: $message';
  }

  @override
  String get saveCancelled => 'Save cancelled.';

  @override
  String get hideTimeline => 'Hide timeline';

  @override
  String get showTimeline => 'Show timeline';

  @override
  String get resumeEditing => 'Continue editing';

  @override
  String resumeEditingSubtitle(int count, String updated) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count text layers · updated $updated',
      zero: 'No text layers · updated $updated',
    );
    return '$_temp0';
  }

  @override
  String get projectNotFound => 'Saved project could not be found.';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get exportQualitySection => 'Export quality';

  @override
  String get exportQualityRecommendedTitle => 'Recommended';

  @override
  String get exportQualityRecommendedBody =>
      '1080p cap, no upscale. Stream copy when only trimming — like CapCut\'s default.';

  @override
  String get exportQualityHighTitle => 'Higher quality';

  @override
  String get exportQualityHighBody =>
      'Best detail (CRF 18). Always re-encodes; takes longer.';

  @override
  String get exportQualitySmallerTitle => 'Smaller file';

  @override
  String get exportQualitySmallerBody =>
      'Faster export and smaller files. Stream copy when only trimming.';

  @override
  String get exportQualityOriginalTitle => 'Match original';

  @override
  String get exportQualityOriginalBody =>
      'Keeps the source bitstream when possible. Light encode only when text or rotation is added.';

  @override
  String get addMusic => 'Add music';

  @override
  String get importMusicFile => 'Import audio file';

  @override
  String get searchMusicHint => 'Search royalty-free music';

  @override
  String get musicCatalogAttribution =>
      'Free for commercial use. Attribution not required (Pixabay / Mixkit).';

  @override
  String get musicCatalogUnavailable =>
      'Could not load the music catalog. Import a file, or check the text template server URL.';

  @override
  String get musicLocalOnlyHint =>
      'Import an MP3, M4A, or WAV file from your device.';

  @override
  String get musicNoResults => 'No tracks found.';

  @override
  String musicImportFailed(String message) {
    return 'Could not add music: $message';
  }

  @override
  String get useMusicTrack => 'Use';

  @override
  String get musicPreviewFailed => 'Could not preview this track.';

  @override
  String get removeMusic => 'Remove music';

  @override
  String get retry => 'Retry';

  @override
  String get musicCatalogSection => 'Music catalog';

  @override
  String get musicCatalogReady => 'Pixabay Music';

  @override
  String get musicCatalogBody =>
      'Royalty-free music for commercial use — no attribution required. Uses Pixabay when PIXABAY_API_KEY is set on the server; otherwise Mixkit.';

  @override
  String get splitVideo => 'Split clip';

  @override
  String get deleteSegment => 'Delete segment';

  @override
  String get splitOutOfRange => 'Move the playhead inside the clip to split.';

  @override
  String get splitTooShort => 'Each part must be at least 1 second.';

  @override
  String get splitFailed => 'Could not split the clip.';

  @override
  String splitSuccess(String time) {
    return 'Split at $time';
  }

  @override
  String get cannotDeleteLastSegment =>
      'At least one clip segment must remain.';

  @override
  String get undo => 'Undo';

  @override
  String get redo => 'Redo';
}
