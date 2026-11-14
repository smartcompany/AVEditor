// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'ClipGo';

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
  String get addTemplateText => 'Add template text';

  @override
  String get rotateVideo => 'Rotate video';

  @override
  String get export => 'Export';

  @override
  String get uploadShorts => 'Upload Shorts';

  @override
  String get saveToGallery => 'Save to gallery';

  @override
  String get saveToAlbum => 'Save to album';

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
  String get youtubeUploadNeedsSignIn =>
      'Sign in with YouTube before uploading. Sign-in is not connected yet, so the upload was not started.';

  @override
  String get trimStart => 'Trim start';

  @override
  String get trimEnd => 'Trim end';

  @override
  String get textOverlayHint => 'Tap to enter text';

  @override
  String get uploadTitleHint => 'Short title';

  @override
  String get uploadDescriptionHint =>
      'Description (optional, #Shorts recommended)';

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
  String get deleteTextConfirm => 'Delete this text?';

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
  String get textStudioTabTemplates => 'Text';

  @override
  String get textStudioTabTextTemplates => 'Text templates';

  @override
  String get textStudioTabFonts => 'Fonts';

  @override
  String get textStudioTabStyle => 'Style';

  @override
  String get textStudioTabEffects => 'Edit effects';

  @override
  String get textStudioTabAnimation => 'Animation';

  @override
  String get textStudioTabBubbles => 'Bubbles';

  @override
  String get textStudioDefault => 'Default';

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
  String get convertingVideo => 'Converting video…';

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
  String get projectsSection => 'Projects';

  @override
  String get noProjectsYet => 'No projects yet. Choose a video above to start.';

  @override
  String projectListSubtitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count text layers',
      zero: 'No text layers',
    );
    return '$_temp0';
  }

  @override
  String get deleteProject => 'Delete project';

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
  String get searchSfxHint => 'Search sound effects';

  @override
  String get musicTabMusic => 'Music';

  @override
  String get musicTabSfx => 'Sound effects';

  @override
  String get musicGenreAll => 'All';

  @override
  String get musicGenreTravel => 'Travel';

  @override
  String get musicGenreBeauty => 'Beauty';

  @override
  String get musicGenreFashion => 'Fashion';

  @override
  String get musicGenreHappy => 'Upbeat';

  @override
  String get musicGenreEnergetic => 'Energetic';

  @override
  String get musicGenreChill => 'Chill';

  @override
  String get musicGenreCinematic => 'Cinematic';

  @override
  String get musicGenreRomantic => 'Romantic';

  @override
  String get musicGenreSports => 'Sports';

  @override
  String get musicGenreNature => 'Nature';

  @override
  String get musicGenreCooking => 'Cooking';

  @override
  String get musicGenreCorporate => 'Corporate';

  @override
  String get musicGenreHipHop => 'Hip Hop';

  @override
  String get musicGenrePop => 'Pop';

  @override
  String get musicGenreKids => 'Kids';

  @override
  String get sfxGenreWhoosh => 'Whoosh';

  @override
  String get sfxGenreTransition => 'Transition';

  @override
  String get sfxGenreImpact => 'Impact';

  @override
  String get sfxGenreGlitch => 'Glitch';

  @override
  String get sfxGenreNotification => 'Notification';

  @override
  String get sfxGenreGame => 'Game';

  @override
  String get sfxGenreTech => 'Tech';

  @override
  String get sfxGenreUi => 'UI';

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
  String get transition => 'Transition';

  @override
  String get transitionSheetTitle => 'Transitions';

  @override
  String get transitionSheetSubtitle =>
      'Applied to the cut nearest the playhead.';

  @override
  String get transitionNone => 'None';

  @override
  String get transitionCatalogUnavailable => 'Could not load transitions.';

  @override
  String get transitionApplied => 'Transition applied.';

  @override
  String get transitionNeedsCuts => 'Split the clip first to add a transition.';

  @override
  String get transitionDuration => 'Duration';

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

  @override
  String get uploadVisibility => 'Visibility';

  @override
  String get uploadThumbnail => 'Thumbnail';

  @override
  String get uploadThumbnailSelect => 'Select thumbnail';

  @override
  String get uploadThumbnailAuto => 'Automatic';

  @override
  String get uploadThumbnailFromPhoto => 'Choose photo';

  @override
  String get uploadPlaylist => 'Playlist';

  @override
  String get uploadPlaylistNone => 'Don\'t add to a playlist';

  @override
  String get uploadPlaylistLoad => 'Load playlists';

  @override
  String get uploadPlaylistEmpty => 'This channel has no playlists.';

  @override
  String get uploadPlaylistFailed => 'Could not load playlists.';

  @override
  String get uploadAudience => 'Audience';

  @override
  String get uploadAudienceNotForKids => 'Not made for kids';

  @override
  String get uploadAudienceForKids => 'Made for kids';

  @override
  String get uploadAudienceHelp =>
      'YouTube requires this. Made-for-kids videos have limited features.';

  @override
  String get uploadAgeRestriction => 'Age restriction';

  @override
  String get uploadAgeRestrictionHelp =>
      'Only viewers 18 and older can watch. Unavailable for kids content.';

  @override
  String get uploadMoreDetails => 'More';

  @override
  String get uploadFewerDetails => 'See less';

  @override
  String get uploadShortsCaption => 'Add a Shorts description';

  @override
  String get uploadLocation => 'Location';

  @override
  String get uploadLocationHint => 'Place name';

  @override
  String get uploadLocationNotFound => 'That place could not be found.';

  @override
  String get uploadRelatedVideo => 'Related video';

  @override
  String get uploadRelatedVideoHint => 'YouTube link or video ID';

  @override
  String get uploadRelatedVideoInvalid => 'Check the related video link.';

  @override
  String get uploadPaidPromotion => 'Paid promotion and brand';

  @override
  String get uploadPaidPromotionHelp =>
      'Turn on when the video includes paid product placement. This is sent to YouTube.';

  @override
  String get uploadAlteredContent => 'Altered or synthetic content';

  @override
  String get uploadAlteredContentHelp =>
      'Turn on when the video shows realistic AI or altered footage.';

  @override
  String get uploadTags => 'Tags';

  @override
  String get uploadTagsHint => 'Separate with commas';

  @override
  String get exportComplete => 'Export complete';

  @override
  String get savedToDevice => 'Saved to device';

  @override
  String get exportDone => 'Done';

  @override
  String get shareToYouTube => 'Share to YouTube';

  @override
  String get shareMore => 'More';

  @override
  String get shareAppMissing => 'That app is not installed.';

  @override
  String uploadPartialFailure(String videoId, String message) {
    return 'The video was uploaded ($videoId). A later step failed: $message';
  }

  @override
  String get canvasRatio => 'Ratio';

  @override
  String get canvasRatioOriginal => 'Original';

  @override
  String get textColorCustom => 'Custom color';

  @override
  String get textColorDone => 'Done';

  @override
  String projectDefaultName(int n) {
    return 'Project $n';
  }

  @override
  String get projectNameTitle => 'Project name';

  @override
  String get projectNameHint => 'Enter a project name';

  @override
  String proTitle(String appName) {
    return '$appName Pro';
  }

  @override
  String get proSubtitle =>
      'Unlock every effect and make your Shorts stand out.';

  @override
  String get proBenefitEffects => 'All Pro transitions and text effects';

  @override
  String get proBenefitNoAds => 'Export without ads';

  @override
  String get proBenefitFuture => 'New Pro features as they arrive';

  @override
  String get proSubscribe => 'Start Pro';

  @override
  String get proRestore => 'Restore purchases';

  @override
  String get proAnnualBadge => 'Best value';

  @override
  String get proLegal =>
      'Subscriptions renew automatically. Cancel anytime in your store account settings.';

  @override
  String get proStoreUnavailable => 'The store isn\'t connected yet.';

  @override
  String get proDebugToggle => 'Test Pro (debug only)';

  @override
  String get proActive => 'Pro is active';

  @override
  String get proInactive => 'Free plan';

  @override
  String get proPurchaseFailed =>
      'The purchase didn\'t go through. Please try again.';

  @override
  String get proRestoreNone => 'No purchases to restore.';

  @override
  String get proSection => 'Subscription';

  @override
  String get premiumExportTitle => 'Pro effects are in this video';

  @override
  String get premiumExportBody => 'Choose how to save it.';

  @override
  String get premiumExportWithPro => 'Save with Pro';

  @override
  String get premiumExportWatchAd => 'Watch an ad to save this once';

  @override
  String get premiumExportStrip => 'Save without Pro effects';

  @override
  String get premiumAdNotFinished => 'Watch the whole ad to unlock this save.';

  @override
  String get uploadAccountTitle => 'YouTube account';

  @override
  String get uploadAccountNone => 'No account connected yet';

  @override
  String get uploadAccountConnect => 'Connect';

  @override
  String get uploadAccountSwitch => 'Switch';

  @override
  String get uploadErrorTitle => 'Couldn\'t upload';

  @override
  String get uploadErrSuspended =>
      'The YouTube channel on this Google account is suspended, so videos can\'t be uploaded. Please sign in with another account.';

  @override
  String get uploadErrNoChannel =>
      'This Google account doesn\'t have a YouTube channel yet. Create one in the YouTube app and try again, or sign in with another account.';

  @override
  String get uploadErrUploadLimit =>
      'This channel has reached today\'s upload limit. Please try again in 24 hours.';

  @override
  String get uploadErrQuota =>
      'YouTube is busy right now and couldn\'t take the upload. Please try again in a little while.';

  @override
  String get uploadErrAuth => 'Your sign-in has expired. Please sign in again.';

  @override
  String get uploadErrPermission =>
      'Allow the YouTube upload permission to upload your video.';

  @override
  String get uploadErrNetwork =>
      'The connection is unstable. Check your internet connection and try again.';

  @override
  String get uploadErrUnknown =>
      'Please try again in a moment. If it keeps happening, let us know the code below.';

  @override
  String uploadErrCode(String code) {
    return 'Error code: $code';
  }

  @override
  String get uploadSwitchAccountAction => 'Use another account';

  @override
  String uploadPartialDone(String steps) {
    return 'Your video was uploaded, but these settings couldn\'t be applied: $steps. You can change them in YouTube Studio.';
  }

  @override
  String get uploadStepThumbnail => 'thumbnail';

  @override
  String get uploadStepPlaylist => 'playlist';

  @override
  String get uploadStepAgeRestriction => 'age restriction';

  @override
  String get uploadStepLocation => 'location';

  @override
  String get uploadOk => 'OK';

  @override
  String get uploadDoneTitle => 'Uploaded to YouTube';

  @override
  String get uploadDoneProcessing =>
      'YouTube may take a few minutes to process it, so it might not play right away.';

  @override
  String uploadDoneVisibility(String visibility) {
    return 'Visibility: $visibility';
  }

  @override
  String get uploadDoneOpen => 'Watch on YouTube';

  @override
  String get uploadDoneCopy => 'Copy link';

  @override
  String get uploadDoneCopied => 'Link copied';

  @override
  String get uploadDoneShare => 'Share';

  @override
  String get uploadDoneClose => 'Done';
}
