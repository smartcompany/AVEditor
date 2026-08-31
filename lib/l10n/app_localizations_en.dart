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
}
