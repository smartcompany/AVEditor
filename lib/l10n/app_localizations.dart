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
  /// **'EasyClip'**
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

  /// No description provided for @addTemplateText.
  ///
  /// In en, this message translates to:
  /// **'Add template text'**
  String get addTemplateText;

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

  /// No description provided for @saveToAlbum.
  ///
  /// In en, this message translates to:
  /// **'Save to album'**
  String get saveToAlbum;

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

  /// No description provided for @youtubeUploadNeedsSignIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in with YouTube before uploading. Sign-in is not connected yet, so the upload was not started.'**
  String get youtubeUploadNeedsSignIn;

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
  /// **'Tap to enter text'**
  String get textOverlayHint;

  /// No description provided for @uploadTitleHint.
  ///
  /// In en, this message translates to:
  /// **'Short title'**
  String get uploadTitleHint;

  /// No description provided for @uploadDescriptionHint.
  ///
  /// In en, this message translates to:
  /// **'Description (optional, #Shorts recommended)'**
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

  /// No description provided for @deleteTextConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete this text?'**
  String get deleteTextConfirm;

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

  /// No description provided for @textTemplates.
  ///
  /// In en, this message translates to:
  /// **'Word Art'**
  String get textTemplates;

  /// No description provided for @textTemplatePacks.
  ///
  /// In en, this message translates to:
  /// **'Packs'**
  String get textTemplatePacks;

  /// No description provided for @textStudioTabTemplates.
  ///
  /// In en, this message translates to:
  /// **'Text'**
  String get textStudioTabTemplates;

  /// No description provided for @textStudioTabTextTemplates.
  ///
  /// In en, this message translates to:
  /// **'Text templates'**
  String get textStudioTabTextTemplates;

  /// No description provided for @textStudioTabFonts.
  ///
  /// In en, this message translates to:
  /// **'Fonts'**
  String get textStudioTabFonts;

  /// No description provided for @textStudioTabStyle.
  ///
  /// In en, this message translates to:
  /// **'Style'**
  String get textStudioTabStyle;

  /// No description provided for @textStudioTabEffects.
  ///
  /// In en, this message translates to:
  /// **'Edit effects'**
  String get textStudioTabEffects;

  /// No description provided for @textStudioTabAnimation.
  ///
  /// In en, this message translates to:
  /// **'Animation'**
  String get textStudioTabAnimation;

  /// No description provided for @textStudioTabBubbles.
  ///
  /// In en, this message translates to:
  /// **'Bubbles'**
  String get textStudioTabBubbles;

  /// No description provided for @textStudioDefault.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get textStudioDefault;

  /// No description provided for @textPackSection.
  ///
  /// In en, this message translates to:
  /// **'Text template server'**
  String get textPackSection;

  /// No description provided for @textPackUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'Pack base URL'**
  String get textPackUrlLabel;

  /// No description provided for @textPackUrlBody.
  ///
  /// In en, this message translates to:
  /// **'Vercel URL for Word Art packs (catalog.json + Lottie). Leave empty to use bundled packs only.'**
  String get textPackUrlBody;

  /// No description provided for @textPackUrlSaved.
  ///
  /// In en, this message translates to:
  /// **'Pack server updated.'**
  String get textPackUrlSaved;

  /// No description provided for @textPackUrlSavePartial.
  ///
  /// In en, this message translates to:
  /// **'Saved, but remote catalog could not be reached. Bundled packs still work.'**
  String get textPackUrlSavePartial;

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

  /// No description provided for @convertingVideo.
  ///
  /// In en, this message translates to:
  /// **'Converting video…'**
  String get convertingVideo;

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

  /// No description provided for @projectsSection.
  ///
  /// In en, this message translates to:
  /// **'Projects'**
  String get projectsSection;

  /// No description provided for @noProjectsYet.
  ///
  /// In en, this message translates to:
  /// **'No projects yet. Choose a video above to start.'**
  String get noProjectsYet;

  /// No description provided for @projectListSubtitle.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No text layers} other{{count} text layers}}'**
  String projectListSubtitle(int count);

  /// No description provided for @deleteProject.
  ///
  /// In en, this message translates to:
  /// **'Delete project'**
  String get deleteProject;

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

  /// No description provided for @searchSfxHint.
  ///
  /// In en, this message translates to:
  /// **'Search sound effects'**
  String get searchSfxHint;

  /// No description provided for @musicTabMusic.
  ///
  /// In en, this message translates to:
  /// **'Music'**
  String get musicTabMusic;

  /// No description provided for @musicTabSfx.
  ///
  /// In en, this message translates to:
  /// **'Sound effects'**
  String get musicTabSfx;

  /// No description provided for @musicGenreAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get musicGenreAll;

  /// No description provided for @musicGenreTravel.
  ///
  /// In en, this message translates to:
  /// **'Travel'**
  String get musicGenreTravel;

  /// No description provided for @musicGenreBeauty.
  ///
  /// In en, this message translates to:
  /// **'Beauty'**
  String get musicGenreBeauty;

  /// No description provided for @musicGenreFashion.
  ///
  /// In en, this message translates to:
  /// **'Fashion'**
  String get musicGenreFashion;

  /// No description provided for @musicGenreHappy.
  ///
  /// In en, this message translates to:
  /// **'Upbeat'**
  String get musicGenreHappy;

  /// No description provided for @musicGenreEnergetic.
  ///
  /// In en, this message translates to:
  /// **'Energetic'**
  String get musicGenreEnergetic;

  /// No description provided for @musicGenreChill.
  ///
  /// In en, this message translates to:
  /// **'Chill'**
  String get musicGenreChill;

  /// No description provided for @musicGenreCinematic.
  ///
  /// In en, this message translates to:
  /// **'Cinematic'**
  String get musicGenreCinematic;

  /// No description provided for @musicGenreRomantic.
  ///
  /// In en, this message translates to:
  /// **'Romantic'**
  String get musicGenreRomantic;

  /// No description provided for @musicGenreSports.
  ///
  /// In en, this message translates to:
  /// **'Sports'**
  String get musicGenreSports;

  /// No description provided for @musicGenreNature.
  ///
  /// In en, this message translates to:
  /// **'Nature'**
  String get musicGenreNature;

  /// No description provided for @musicGenreCooking.
  ///
  /// In en, this message translates to:
  /// **'Cooking'**
  String get musicGenreCooking;

  /// No description provided for @musicGenreCorporate.
  ///
  /// In en, this message translates to:
  /// **'Corporate'**
  String get musicGenreCorporate;

  /// No description provided for @musicGenreHipHop.
  ///
  /// In en, this message translates to:
  /// **'Hip Hop'**
  String get musicGenreHipHop;

  /// No description provided for @musicGenrePop.
  ///
  /// In en, this message translates to:
  /// **'Pop'**
  String get musicGenrePop;

  /// No description provided for @musicGenreKids.
  ///
  /// In en, this message translates to:
  /// **'Kids'**
  String get musicGenreKids;

  /// No description provided for @sfxGenreWhoosh.
  ///
  /// In en, this message translates to:
  /// **'Whoosh'**
  String get sfxGenreWhoosh;

  /// No description provided for @sfxGenreTransition.
  ///
  /// In en, this message translates to:
  /// **'Transition'**
  String get sfxGenreTransition;

  /// No description provided for @sfxGenreImpact.
  ///
  /// In en, this message translates to:
  /// **'Impact'**
  String get sfxGenreImpact;

  /// No description provided for @sfxGenreGlitch.
  ///
  /// In en, this message translates to:
  /// **'Glitch'**
  String get sfxGenreGlitch;

  /// No description provided for @sfxGenreNotification.
  ///
  /// In en, this message translates to:
  /// **'Notification'**
  String get sfxGenreNotification;

  /// No description provided for @sfxGenreGame.
  ///
  /// In en, this message translates to:
  /// **'Game'**
  String get sfxGenreGame;

  /// No description provided for @sfxGenreTech.
  ///
  /// In en, this message translates to:
  /// **'Tech'**
  String get sfxGenreTech;

  /// No description provided for @sfxGenreUi.
  ///
  /// In en, this message translates to:
  /// **'UI'**
  String get sfxGenreUi;

  /// No description provided for @musicCatalogAttribution.
  ///
  /// In en, this message translates to:
  /// **'Free for commercial use. Attribution not required (Pixabay / Mixkit).'**
  String get musicCatalogAttribution;

  /// No description provided for @musicCatalogUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Could not load the music catalog. Import a file, or check the text template server URL.'**
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

  /// No description provided for @useMusicTrack.
  ///
  /// In en, this message translates to:
  /// **'Use'**
  String get useMusicTrack;

  /// No description provided for @musicPreviewFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not preview this track.'**
  String get musicPreviewFailed;

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

  /// No description provided for @musicCatalogReady.
  ///
  /// In en, this message translates to:
  /// **'Pixabay Music'**
  String get musicCatalogReady;

  /// No description provided for @musicCatalogBody.
  ///
  /// In en, this message translates to:
  /// **'Royalty-free music for commercial use — no attribution required. Uses Pixabay when PIXABAY_API_KEY is set on the server; otherwise Mixkit.'**
  String get musicCatalogBody;

  /// No description provided for @splitVideo.
  ///
  /// In en, this message translates to:
  /// **'Split clip'**
  String get splitVideo;

  /// No description provided for @transition.
  ///
  /// In en, this message translates to:
  /// **'Transition'**
  String get transition;

  /// No description provided for @transitionSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Transitions'**
  String get transitionSheetTitle;

  /// No description provided for @transitionSheetSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Applied to the cut nearest the playhead.'**
  String get transitionSheetSubtitle;

  /// No description provided for @transitionNone.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get transitionNone;

  /// No description provided for @transitionCatalogUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Could not load transitions.'**
  String get transitionCatalogUnavailable;

  /// No description provided for @transitionApplied.
  ///
  /// In en, this message translates to:
  /// **'Transition applied.'**
  String get transitionApplied;

  /// No description provided for @transitionNeedsCuts.
  ///
  /// In en, this message translates to:
  /// **'Split the clip first to add a transition.'**
  String get transitionNeedsCuts;

  /// No description provided for @transitionDuration.
  ///
  /// In en, this message translates to:
  /// **'Duration'**
  String get transitionDuration;

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

  /// No description provided for @uploadVisibility.
  ///
  /// In en, this message translates to:
  /// **'Visibility'**
  String get uploadVisibility;

  /// No description provided for @uploadThumbnail.
  ///
  /// In en, this message translates to:
  /// **'Thumbnail'**
  String get uploadThumbnail;

  /// No description provided for @uploadThumbnailSelect.
  ///
  /// In en, this message translates to:
  /// **'Select thumbnail'**
  String get uploadThumbnailSelect;

  /// No description provided for @uploadThumbnailAuto.
  ///
  /// In en, this message translates to:
  /// **'Automatic'**
  String get uploadThumbnailAuto;

  /// No description provided for @uploadThumbnailFromPhoto.
  ///
  /// In en, this message translates to:
  /// **'Choose photo'**
  String get uploadThumbnailFromPhoto;

  /// No description provided for @uploadPlaylist.
  ///
  /// In en, this message translates to:
  /// **'Playlist'**
  String get uploadPlaylist;

  /// No description provided for @uploadPlaylistNone.
  ///
  /// In en, this message translates to:
  /// **'Don\'t add to a playlist'**
  String get uploadPlaylistNone;

  /// No description provided for @uploadPlaylistLoad.
  ///
  /// In en, this message translates to:
  /// **'Load playlists'**
  String get uploadPlaylistLoad;

  /// No description provided for @uploadPlaylistEmpty.
  ///
  /// In en, this message translates to:
  /// **'This channel has no playlists.'**
  String get uploadPlaylistEmpty;

  /// No description provided for @uploadPlaylistFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load playlists.'**
  String get uploadPlaylistFailed;

  /// No description provided for @uploadAudience.
  ///
  /// In en, this message translates to:
  /// **'Audience'**
  String get uploadAudience;

  /// No description provided for @uploadAudienceNotForKids.
  ///
  /// In en, this message translates to:
  /// **'Not made for kids'**
  String get uploadAudienceNotForKids;

  /// No description provided for @uploadAudienceForKids.
  ///
  /// In en, this message translates to:
  /// **'Made for kids'**
  String get uploadAudienceForKids;

  /// No description provided for @uploadAudienceHelp.
  ///
  /// In en, this message translates to:
  /// **'YouTube requires this. Made-for-kids videos have limited features.'**
  String get uploadAudienceHelp;

  /// No description provided for @uploadAgeRestriction.
  ///
  /// In en, this message translates to:
  /// **'Age restriction'**
  String get uploadAgeRestriction;

  /// No description provided for @uploadAgeRestrictionHelp.
  ///
  /// In en, this message translates to:
  /// **'Only viewers 18 and older can watch. Unavailable for kids content.'**
  String get uploadAgeRestrictionHelp;

  /// No description provided for @uploadMoreDetails.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get uploadMoreDetails;

  /// No description provided for @uploadFewerDetails.
  ///
  /// In en, this message translates to:
  /// **'See less'**
  String get uploadFewerDetails;

  /// No description provided for @uploadShortsCaption.
  ///
  /// In en, this message translates to:
  /// **'Add a Shorts description'**
  String get uploadShortsCaption;

  /// No description provided for @uploadLocation.
  ///
  /// In en, this message translates to:
  /// **'Location'**
  String get uploadLocation;

  /// No description provided for @uploadLocationHint.
  ///
  /// In en, this message translates to:
  /// **'Place name'**
  String get uploadLocationHint;

  /// No description provided for @uploadLocationNotFound.
  ///
  /// In en, this message translates to:
  /// **'That place could not be found.'**
  String get uploadLocationNotFound;

  /// No description provided for @uploadRelatedVideo.
  ///
  /// In en, this message translates to:
  /// **'Related video'**
  String get uploadRelatedVideo;

  /// No description provided for @uploadRelatedVideoHint.
  ///
  /// In en, this message translates to:
  /// **'YouTube link or video ID'**
  String get uploadRelatedVideoHint;

  /// No description provided for @uploadRelatedVideoInvalid.
  ///
  /// In en, this message translates to:
  /// **'Check the related video link.'**
  String get uploadRelatedVideoInvalid;

  /// No description provided for @uploadPaidPromotion.
  ///
  /// In en, this message translates to:
  /// **'Paid promotion and brand'**
  String get uploadPaidPromotion;

  /// No description provided for @uploadPaidPromotionHelp.
  ///
  /// In en, this message translates to:
  /// **'Turn on when the video includes paid product placement. This is sent to YouTube.'**
  String get uploadPaidPromotionHelp;

  /// No description provided for @uploadAlteredContent.
  ///
  /// In en, this message translates to:
  /// **'Altered or synthetic content'**
  String get uploadAlteredContent;

  /// No description provided for @uploadAlteredContentHelp.
  ///
  /// In en, this message translates to:
  /// **'Turn on when the video shows realistic AI or altered footage.'**
  String get uploadAlteredContentHelp;

  /// No description provided for @uploadTags.
  ///
  /// In en, this message translates to:
  /// **'Tags'**
  String get uploadTags;

  /// No description provided for @uploadTagsHint.
  ///
  /// In en, this message translates to:
  /// **'Separate with commas'**
  String get uploadTagsHint;

  /// No description provided for @exportComplete.
  ///
  /// In en, this message translates to:
  /// **'Export complete'**
  String get exportComplete;

  /// No description provided for @savedToDevice.
  ///
  /// In en, this message translates to:
  /// **'Saved to device'**
  String get savedToDevice;

  /// No description provided for @exportDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get exportDone;

  /// No description provided for @shareToYouTube.
  ///
  /// In en, this message translates to:
  /// **'Share to YouTube'**
  String get shareToYouTube;

  /// No description provided for @shareMore.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get shareMore;

  /// No description provided for @shareAppMissing.
  ///
  /// In en, this message translates to:
  /// **'That app is not installed.'**
  String get shareAppMissing;

  /// No description provided for @shareFacebookOpened.
  ///
  /// In en, this message translates to:
  /// **'Choose Facebook in the list to finish posting.'**
  String get shareFacebookOpened;

  /// No description provided for @shareFacebookPosted.
  ///
  /// In en, this message translates to:
  /// **'Posted to Facebook.'**
  String get shareFacebookPosted;

  /// No description provided for @shareFacebookCancelled.
  ///
  /// In en, this message translates to:
  /// **'Facebook post cancelled.'**
  String get shareFacebookCancelled;

  /// No description provided for @shareFacebookFailed.
  ///
  /// In en, this message translates to:
  /// **'Facebook post failed: {message}'**
  String shareFacebookFailed(String message);

  /// No description provided for @uploadPartialFailure.
  ///
  /// In en, this message translates to:
  /// **'The video was uploaded ({videoId}). A later step failed: {message}'**
  String uploadPartialFailure(String videoId, String message);

  /// No description provided for @canvasRatio.
  ///
  /// In en, this message translates to:
  /// **'Ratio'**
  String get canvasRatio;

  /// No description provided for @canvasRatioOriginal.
  ///
  /// In en, this message translates to:
  /// **'Original'**
  String get canvasRatioOriginal;

  /// No description provided for @textColorCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom color'**
  String get textColorCustom;

  /// No description provided for @textColorDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get textColorDone;

  /// No description provided for @projectDefaultName.
  ///
  /// In en, this message translates to:
  /// **'Project {n}'**
  String projectDefaultName(int n);

  /// No description provided for @projectNameTitle.
  ///
  /// In en, this message translates to:
  /// **'Project name'**
  String get projectNameTitle;

  /// No description provided for @projectNameHint.
  ///
  /// In en, this message translates to:
  /// **'Enter a project name'**
  String get projectNameHint;

  /// No description provided for @proTitle.
  ///
  /// In en, this message translates to:
  /// **'{appName} Pro'**
  String proTitle(String appName);

  /// No description provided for @proSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Unlock every effect and make your Shorts stand out.'**
  String get proSubtitle;

  /// No description provided for @proBenefitEffects.
  ///
  /// In en, this message translates to:
  /// **'All Pro transitions and text effects'**
  String get proBenefitEffects;

  /// No description provided for @proBenefitNoAds.
  ///
  /// In en, this message translates to:
  /// **'Export without ads'**
  String get proBenefitNoAds;

  /// No description provided for @proBenefitFuture.
  ///
  /// In en, this message translates to:
  /// **'New Pro features as they arrive'**
  String get proBenefitFuture;

  /// No description provided for @proSubscribe.
  ///
  /// In en, this message translates to:
  /// **'Start Pro'**
  String get proSubscribe;

  /// No description provided for @proRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore purchases'**
  String get proRestore;

  /// No description provided for @proAnnualBadge.
  ///
  /// In en, this message translates to:
  /// **'Best value'**
  String get proAnnualBadge;

  /// No description provided for @proLegal.
  ///
  /// In en, this message translates to:
  /// **'Subscriptions renew automatically. Cancel anytime in your store account settings.'**
  String get proLegal;

  /// No description provided for @proStoreUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The store isn\'t connected yet.'**
  String get proStoreUnavailable;

  /// No description provided for @proDebugToggle.
  ///
  /// In en, this message translates to:
  /// **'Test Pro (debug only)'**
  String get proDebugToggle;

  /// No description provided for @proActive.
  ///
  /// In en, this message translates to:
  /// **'Pro is active'**
  String get proActive;

  /// No description provided for @proInactive.
  ///
  /// In en, this message translates to:
  /// **'Free plan'**
  String get proInactive;

  /// No description provided for @proPurchaseFailed.
  ///
  /// In en, this message translates to:
  /// **'The purchase didn\'t go through. Please try again.'**
  String get proPurchaseFailed;

  /// No description provided for @proRestoreNone.
  ///
  /// In en, this message translates to:
  /// **'No purchases to restore.'**
  String get proRestoreNone;

  /// No description provided for @proSection.
  ///
  /// In en, this message translates to:
  /// **'Subscription'**
  String get proSection;

  /// No description provided for @premiumExportTitle.
  ///
  /// In en, this message translates to:
  /// **'Pro effects are in this video'**
  String get premiumExportTitle;

  /// No description provided for @premiumExportBody.
  ///
  /// In en, this message translates to:
  /// **'Choose how to save it.'**
  String get premiumExportBody;

  /// No description provided for @premiumExportWithPro.
  ///
  /// In en, this message translates to:
  /// **'Save with Pro'**
  String get premiumExportWithPro;

  /// No description provided for @premiumExportWatchAd.
  ///
  /// In en, this message translates to:
  /// **'Watch an ad to save this once'**
  String get premiumExportWatchAd;

  /// No description provided for @premiumExportStrip.
  ///
  /// In en, this message translates to:
  /// **'Save without Pro effects'**
  String get premiumExportStrip;

  /// No description provided for @premiumAdNotFinished.
  ///
  /// In en, this message translates to:
  /// **'Watch the whole ad to unlock this save.'**
  String get premiumAdNotFinished;

  /// No description provided for @uploadAccountTitle.
  ///
  /// In en, this message translates to:
  /// **'YouTube account'**
  String get uploadAccountTitle;

  /// No description provided for @uploadAccountNone.
  ///
  /// In en, this message translates to:
  /// **'No account connected yet'**
  String get uploadAccountNone;

  /// No description provided for @uploadAccountConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get uploadAccountConnect;

  /// No description provided for @uploadAccountSwitch.
  ///
  /// In en, this message translates to:
  /// **'Switch'**
  String get uploadAccountSwitch;

  /// No description provided for @uploadErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t upload'**
  String get uploadErrorTitle;

  /// No description provided for @uploadErrSuspended.
  ///
  /// In en, this message translates to:
  /// **'The YouTube channel on this Google account is suspended, so videos can\'t be uploaded. Please sign in with another account.'**
  String get uploadErrSuspended;

  /// No description provided for @uploadErrNoChannel.
  ///
  /// In en, this message translates to:
  /// **'This Google account doesn\'t have a YouTube channel yet. Create one in the YouTube app and try again, or sign in with another account.'**
  String get uploadErrNoChannel;

  /// No description provided for @uploadErrUploadLimit.
  ///
  /// In en, this message translates to:
  /// **'This channel has reached today\'s upload limit. Please try again in 24 hours.'**
  String get uploadErrUploadLimit;

  /// No description provided for @uploadErrQuota.
  ///
  /// In en, this message translates to:
  /// **'YouTube is busy right now and couldn\'t take the upload. Please try again in a little while.'**
  String get uploadErrQuota;

  /// No description provided for @uploadErrAuth.
  ///
  /// In en, this message translates to:
  /// **'Your sign-in has expired. Please sign in again.'**
  String get uploadErrAuth;

  /// No description provided for @uploadErrPermission.
  ///
  /// In en, this message translates to:
  /// **'Allow the YouTube upload permission to upload your video.'**
  String get uploadErrPermission;

  /// No description provided for @uploadErrNetwork.
  ///
  /// In en, this message translates to:
  /// **'The connection is unstable. Check your internet connection and try again.'**
  String get uploadErrNetwork;

  /// No description provided for @uploadErrUnknown.
  ///
  /// In en, this message translates to:
  /// **'Please try again in a moment. If it keeps happening, let us know the code below.'**
  String get uploadErrUnknown;

  /// No description provided for @uploadErrCode.
  ///
  /// In en, this message translates to:
  /// **'Error code: {code}'**
  String uploadErrCode(String code);

  /// No description provided for @uploadSwitchAccountAction.
  ///
  /// In en, this message translates to:
  /// **'Use another account'**
  String get uploadSwitchAccountAction;

  /// No description provided for @uploadPartialDone.
  ///
  /// In en, this message translates to:
  /// **'Your video was uploaded, but these settings couldn\'t be applied: {steps}. You can change them in YouTube Studio.'**
  String uploadPartialDone(String steps);

  /// No description provided for @uploadStepThumbnail.
  ///
  /// In en, this message translates to:
  /// **'thumbnail'**
  String get uploadStepThumbnail;

  /// No description provided for @uploadStepPlaylist.
  ///
  /// In en, this message translates to:
  /// **'playlist'**
  String get uploadStepPlaylist;

  /// No description provided for @uploadStepAgeRestriction.
  ///
  /// In en, this message translates to:
  /// **'age restriction'**
  String get uploadStepAgeRestriction;

  /// No description provided for @uploadStepLocation.
  ///
  /// In en, this message translates to:
  /// **'location'**
  String get uploadStepLocation;

  /// No description provided for @uploadOk.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get uploadOk;

  /// No description provided for @uploadDoneTitle.
  ///
  /// In en, this message translates to:
  /// **'Uploaded to YouTube'**
  String get uploadDoneTitle;

  /// No description provided for @uploadDoneProcessing.
  ///
  /// In en, this message translates to:
  /// **'YouTube may take a few minutes to process it, so it might not play right away.'**
  String get uploadDoneProcessing;

  /// No description provided for @uploadDoneVisibility.
  ///
  /// In en, this message translates to:
  /// **'Visibility: {visibility}'**
  String uploadDoneVisibility(String visibility);

  /// No description provided for @uploadDoneOpen.
  ///
  /// In en, this message translates to:
  /// **'Watch on YouTube'**
  String get uploadDoneOpen;

  /// No description provided for @uploadDoneCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy link'**
  String get uploadDoneCopy;

  /// No description provided for @uploadDoneCopied.
  ///
  /// In en, this message translates to:
  /// **'Link copied'**
  String get uploadDoneCopied;

  /// No description provided for @uploadDoneShare.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get uploadDoneShare;

  /// No description provided for @uploadDoneClose.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get uploadDoneClose;
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
