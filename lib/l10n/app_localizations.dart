import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ja.dart';
import 'app_localizations_ko.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ja'),
    Locale('ko'),
    Locale('zh'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'AVEditor'**
  String get appTitle;

  /// No description provided for @homeTagline.
  ///
  /// In en, this message translates to:
  /// **'Text on your timeline — upload Shorts in one app.'**
  String get homeTagline;

  /// No description provided for @pickFromGallery.
  ///
  /// In en, this message translates to:
  /// **'Choose from gallery'**
  String get pickFromGallery;

  /// No description provided for @pickFromFiles.
  ///
  /// In en, this message translates to:
  /// **'Choose video file'**
  String get pickFromFiles;

  /// No description provided for @recordVideo.
  ///
  /// In en, this message translates to:
  /// **'Record video'**
  String get recordVideo;

  /// No description provided for @youtubeSignIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in with YouTube'**
  String get youtubeSignIn;

  /// No description provided for @youtubeSignedIn.
  ///
  /// In en, this message translates to:
  /// **'YouTube connected'**
  String get youtubeSignedIn;

  /// No description provided for @youtubeSignOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get youtubeSignOut;

  /// No description provided for @editorTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get editorTitle;

  /// No description provided for @addText.
  ///
  /// In en, this message translates to:
  /// **'Add text'**
  String get addText;

  /// No description provided for @rotateVideo.
  ///
  /// In en, this message translates to:
  /// **'Rotate video'**
  String get rotateVideo;

  /// No description provided for @export.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get export;

  /// No description provided for @uploadShorts.
  ///
  /// In en, this message translates to:
  /// **'Upload Shorts'**
  String get uploadShorts;

  /// No description provided for @saveToGallery.
  ///
  /// In en, this message translates to:
  /// **'Save to gallery'**
  String get saveToGallery;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @videoNotSelected.
  ///
  /// In en, this message translates to:
  /// **'No video selected.'**
  String get videoNotSelected;

  /// No description provided for @videoPickError.
  ///
  /// In en, this message translates to:
  /// **'Could not open video: {message}'**
  String videoPickError(String message);

  /// No description provided for @permissionPhotosDenied.
  ///
  /// In en, this message translates to:
  /// **'Photo library access is off. Enable it in Settings.'**
  String get permissionPhotosDenied;

  /// No description provided for @permissionCameraDenied.
  ///
  /// In en, this message translates to:
  /// **'Camera access is off. Enable it in Settings.'**
  String get permissionCameraDenied;

  /// No description provided for @openSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get openSettings;

  /// No description provided for @comingSoon.
  ///
  /// In en, this message translates to:
  /// **'Coming soon'**
  String get comingSoon;

  /// No description provided for @trimStart.
  ///
  /// In en, this message translates to:
  /// **'Trim start'**
  String get trimStart;

  /// No description provided for @trimEnd.
  ///
  /// In en, this message translates to:
  /// **'Trim end'**
  String get trimEnd;

  /// No description provided for @textOverlayHint.
  ///
  /// In en, this message translates to:
  /// **'Enter text'**
  String get textOverlayHint;

  /// No description provided for @uploadTitleHint.
  ///
  /// In en, this message translates to:
  /// **'Short title'**
  String get uploadTitleHint;

  /// No description provided for @uploadDescriptionHint.
  ///
  /// In en, this message translates to:
  /// **'Description (#Shorts recommended)'**
  String get uploadDescriptionHint;

  /// No description provided for @privacyPublic.
  ///
  /// In en, this message translates to:
  /// **'Public'**
  String get privacyPublic;

  /// No description provided for @privacyUnlisted.
  ///
  /// In en, this message translates to:
  /// **'Unlisted'**
  String get privacyUnlisted;

  /// No description provided for @privacyPrivate.
  ///
  /// In en, this message translates to:
  /// **'Private'**
  String get privacyPrivate;

  /// No description provided for @videoLoadError.
  ///
  /// In en, this message translates to:
  /// **'Could not load video.'**
  String get videoLoadError;

  /// No description provided for @editText.
  ///
  /// In en, this message translates to:
  /// **'Edit text'**
  String get editText;

  /// No description provided for @deleteText.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get deleteText;

  /// No description provided for @fontSize.
  ///
  /// In en, this message translates to:
  /// **'Size'**
  String get fontSize;

  /// No description provided for @textColor.
  ///
  /// In en, this message translates to:
  /// **'Color'**
  String get textColor;

  /// No description provided for @textStyle.
  ///
  /// In en, this message translates to:
  /// **'Style'**
  String get textStyle;

  /// No description provided for @textStyleCycle.
  ///
  /// In en, this message translates to:
  /// **'Cycle text style'**
  String get textStyleCycle;

  /// No description provided for @timelineClip.
  ///
  /// In en, this message translates to:
  /// **'Clip'**
  String get timelineClip;

  /// No description provided for @timelineText.
  ///
  /// In en, this message translates to:
  /// **'Text tracks'**
  String get timelineText;

  /// No description provided for @selectedText.
  ///
  /// In en, this message translates to:
  /// **'Selected text'**
  String get selectedText;

  /// No description provided for @noTextSelected.
  ///
  /// In en, this message translates to:
  /// **'Tap a text bar to edit timing'**
  String get noTextSelected;

  /// No description provided for @durationTotal.
  ///
  /// In en, this message translates to:
  /// **'Total {duration}'**
  String durationTotal(String duration);

  /// No description provided for @trimmedDuration.
  ///
  /// In en, this message translates to:
  /// **'Clip {duration}'**
  String trimmedDuration(String duration);

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @exporting.
  ///
  /// In en, this message translates to:
  /// **'Exporting video…'**
  String get exporting;

  /// No description provided for @exportSuccess.
  ///
  /// In en, this message translates to:
  /// **'Saved to your library.'**
  String get exportSuccess;

  /// No description provided for @exportFailed.
  ///
  /// In en, this message translates to:
  /// **'Export failed.'**
  String get exportFailed;

  /// No description provided for @exportFailedWithMessage.
  ///
  /// In en, this message translates to:
  /// **'Export failed: {message}'**
  String exportFailedWithMessage(String message);

  /// No description provided for @saveCancelled.
  ///
  /// In en, this message translates to:
  /// **'Save cancelled.'**
  String get saveCancelled;

  /// No description provided for @hideTimeline.
  ///
  /// In en, this message translates to:
  /// **'Hide timeline'**
  String get hideTimeline;

  /// No description provided for @showTimeline.
  ///
  /// In en, this message translates to:
  /// **'Show timeline'**
  String get showTimeline;

  /// No description provided for @resumeEditing.
  ///
  /// In en, this message translates to:
  /// **'Continue editing'**
  String get resumeEditing;

  /// No description provided for @resumeEditingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No text layers · updated {updated}} other{{count} text layers · updated {updated}}}'**
  String resumeEditingSubtitle(int count, String updated);

  /// No description provided for @projectNotFound.
  ///
  /// In en, this message translates to:
  /// **'Saved project could not be found.'**
  String get projectNotFound;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @exportQualitySection.
  ///
  /// In en, this message translates to:
  /// **'Export quality'**
  String get exportQualitySection;

  /// No description provided for @exportQualityRecommendedTitle.
  ///
  /// In en, this message translates to:
  /// **'Recommended'**
  String get exportQualityRecommendedTitle;

  /// No description provided for @exportQualityRecommendedBody.
  ///
  /// In en, this message translates to:
  /// **'1080p cap, no upscale. Stream copy when only trimming — like CapCut\'s default.'**
  String get exportQualityRecommendedBody;

  /// No description provided for @exportQualityHighTitle.
  ///
  /// In en, this message translates to:
  /// **'Higher quality'**
  String get exportQualityHighTitle;

  /// No description provided for @exportQualityHighBody.
  ///
  /// In en, this message translates to:
  /// **'Best detail (CRF 18). Always re-encodes; takes longer.'**
  String get exportQualityHighBody;

  /// No description provided for @exportQualitySmallerTitle.
  ///
  /// In en, this message translates to:
  /// **'Smaller file'**
  String get exportQualitySmallerTitle;

  /// No description provided for @exportQualitySmallerBody.
  ///
  /// In en, this message translates to:
  /// **'Faster export and smaller files. Stream copy when only trimming.'**
  String get exportQualitySmallerBody;

  /// No description provided for @exportQualityOriginalTitle.
  ///
  /// In en, this message translates to:
  /// **'Match original'**
  String get exportQualityOriginalTitle;

  /// No description provided for @exportQualityOriginalBody.
  ///
  /// In en, this message translates to:
  /// **'Keeps the source bitstream when possible. Light encode only when text or rotation is added.'**
  String get exportQualityOriginalBody;

  /// No description provided for @addMusic.
  ///
  /// In en, this message translates to:
  /// **'Add music'**
  String get addMusic;

  /// No description provided for @importMusicFile.
  ///
  /// In en, this message translates to:
  /// **'Import audio file'**
  String get importMusicFile;

  /// No description provided for @searchMusicHint.
  ///
  /// In en, this message translates to:
  /// **'Search royalty-free music'**
  String get searchMusicHint;

  /// No description provided for @musicCatalogAttribution.
  ///
  /// In en, this message translates to:
  /// **'Music by Jamendo — Creative Commons. Attribution may be required.'**
  String get musicCatalogAttribution;

  /// No description provided for @musicCatalogUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Online catalog is off. Import an audio file, or build with JAMENDO_CLIENT_ID.'**
  String get musicCatalogUnavailable;

  /// No description provided for @musicLocalOnlyHint.
  ///
  /// In en, this message translates to:
  /// **'Import an MP3, M4A, or WAV file from your device.'**
  String get musicLocalOnlyHint;

  /// No description provided for @musicNoResults.
  ///
  /// In en, this message translates to:
  /// **'No tracks found.'**
  String get musicNoResults;

  /// No description provided for @musicImportFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not add music: {message}'**
  String musicImportFailed(String message);

  /// No description provided for @removeMusic.
  ///
  /// In en, this message translates to:
  /// **'Remove music'**
  String get removeMusic;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @musicCatalogSection.
  ///
  /// In en, this message translates to:
  /// **'Music catalog'**
  String get musicCatalogSection;

  /// No description provided for @musicCatalogBody.
  ///
  /// In en, this message translates to:
  /// **'Jamendo provides free Creative Commons tracks. Register at devportal.jamendo.com and pass --dart-define=JAMENDO_CLIENT_ID=your_id when building.'**
  String get musicCatalogBody;

  /// No description provided for @splitVideo.
  ///
  /// In en, this message translates to:
  /// **'Split clip'**
  String get splitVideo;

  /// No description provided for @deleteSegment.
  ///
  /// In en, this message translates to:
  /// **'Delete segment'**
  String get deleteSegment;

  /// No description provided for @splitOutOfRange.
  ///
  /// In en, this message translates to:
  /// **'Move the playhead inside the clip to split.'**
  String get splitOutOfRange;

  /// No description provided for @splitTooShort.
  ///
  /// In en, this message translates to:
  /// **'Each part must be at least 1 second.'**
  String get splitTooShort;

  /// No description provided for @splitFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not split the clip.'**
  String get splitFailed;

  /// No description provided for @splitSuccess.
  ///
  /// In en, this message translates to:
  /// **'Split at {time}'**
  String splitSuccess(String time);

  /// No description provided for @cannotDeleteLastSegment.
  ///
  /// In en, this message translates to:
  /// **'At least one clip segment must remain.'**
  String get cannotDeleteLastSegment;

  /// No description provided for @undo.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get undo;

  /// No description provided for @redo.
  ///
  /// In en, this message translates to:
  /// **'Redo'**
  String get redo;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ja', 'ko', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ja':
      return AppLocalizationsJa();
    case 'ko':
      return AppLocalizationsKo();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
