// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Korean (`ko`).
class AppLocalizationsKo extends AppLocalizations {
  AppLocalizationsKo([String locale = 'ko']) : super(locale);

  @override
  String get appTitle => 'EasyClip';

  @override
  String get pickFromGallery => '갤러리에서 선택';

  @override
  String get addTimelineMedia => '영상 또는 사진 추가';

  @override
  String get galleryPickerTitle => '갤러리';

  @override
  String get galleryPickerHint => '미디어를 탭하면 미리보기, 동그라미로 선택하세요.';

  @override
  String get galleryPickerEmpty => '사진이나 영상이 없습니다.';

  @override
  String gallerySelectedCount(int count) {
    return '$count개 선택됨';
  }

  @override
  String get galleryAddSelected => '추가';

  @override
  String galleryAddSelectedCount(int count) {
    return '추가 ($count)';
  }

  @override
  String get gallerySelect => '선택';

  @override
  String get galleryDeselect => '선택 해제';

  @override
  String get gallerySelectToggle => '선택 전환';

  @override
  String get galleryPhotoPreview => '사진';

  @override
  String get galleryVideoPreview => '영상';

  @override
  String get galleryBackToGrid => '뒤로';

  @override
  String get galleryManageAccess => '관리';

  @override
  String get galleryRetry => '다시 시도';

  @override
  String get galleryTabGallery => '갤러리';

  @override
  String get galleryTabBackgrounds => '배경';

  @override
  String get galleryBackgroundsEmpty => '배경 템플릿이 없습니다.';

  @override
  String galleryBackgroundsLoadFailed(String error) {
    return '배경을 불러오지 못했습니다: $error';
  }

  @override
  String get pickFromFiles => '동영상 파일 선택';

  @override
  String get recordVideo => '동영상 촬영';

  @override
  String get youtubeSignIn => 'YouTube 로그인';

  @override
  String get youtubeSignedIn => 'YouTube 연결됨';

  @override
  String get youtubeSignOut => '로그아웃';

  @override
  String get editorTitle => '편집';

  @override
  String get addText => '텍스트 추가';

  @override
  String get addSticker => '스티커 추가';

  @override
  String get stickerSearchHint => 'Giphy 스티커 검색';

  @override
  String get stickerPoweredByGiphy => 'Powered by GIPHY';

  @override
  String get stickerApiKeyMissing => 'Giphy API 키가 설정되지 않았습니다.';

  @override
  String get stickerLoadFailed => '스티커를 불러오지 못했습니다.';

  @override
  String get stickerDownloadFailed => '스티커를 받지 못했습니다.';

  @override
  String get stickerEmpty => '스티커가 없습니다.';

  @override
  String get addTemplateText => '템플릿 텍스트 추가';

  @override
  String get rotateVideo => '영상 회전';

  @override
  String get export => '내보내기';

  @override
  String get uploadShorts => 'YouTube에 업로드';

  @override
  String get uploadShortsAndTikTok => 'YouTube·TikTok에 업로드';

  @override
  String get crossPostAlsoTikTok => 'TikTok에도 게시';

  @override
  String get crossPostAlsoYouTube => 'YouTube에도 업로드';

  @override
  String get shareTileWithTikTok => 'TikTok과 함께 가능';

  @override
  String get shareTileWithYouTube => 'YouTube와 함께 가능';

  @override
  String get crossPostTikTokOk => 'TikTok에도 게시했어요';

  @override
  String get crossPostTikTokOkPrivate => 'TikTok에도 게시했어요 (나만 보기 · 앱 심사 전 제한)';

  @override
  String get crossPostYouTubeOk => 'YouTube에도 업로드했어요';

  @override
  String crossPostTikTokFailed(String message) {
    return 'YouTube는 올렸지만 TikTok 실패: $message';
  }

  @override
  String crossPostYouTubeFailed(String message) {
    return 'TikTok은 올렸지만 YouTube 실패: $message';
  }

  @override
  String get saveToGallery => '갤러리에 저장';

  @override
  String get saveToAlbum => '앨범에 저장';

  @override
  String get cancel => '취소';

  @override
  String get videoNotSelected => '동영상이 선택되지 않았습니다.';

  @override
  String videoPickError(String message) {
    return '동영상을 열 수 없습니다: $message';
  }

  @override
  String get videoPickEmpty =>
      '동영상을 열 수 없습니다. iCloud에만 있는 영상이면 사진 앱에서 먼저 다운로드한 뒤 다시 시도하세요.';

  @override
  String get permissionPhotosDenied => '사진 라이브러리 접근이 꺼져 있습니다. 설정에서 허용해 주세요.';

  @override
  String get permissionCameraDenied => '카메라 접근이 꺼져 있습니다. 설정에서 허용해 주세요.';

  @override
  String get openSettings => '설정';

  @override
  String get comingSoon => '준비 중';

  @override
  String get youtubeUploadNeedsSignIn =>
      'YouTube에 로그인한 뒤에 업로드할 수 있습니다. 로그인 연결이 아직 없어서 업로드를 시작하지 않았습니다.';

  @override
  String get trimStart => '시작 지점';

  @override
  String get trimEnd => '끝 지점';

  @override
  String get textOverlayHint => '탭 해서 텍스트 입력';

  @override
  String get uploadTitleHint => '동영상 제목';

  @override
  String get uploadDescriptionHint => '설명 (선택)';

  @override
  String get privacyPublic => '공개';

  @override
  String get privacyUnlisted => '일부 공개';

  @override
  String get privacyPrivate => '비공개';

  @override
  String get videoLoadError => '동영상을 불러올 수 없습니다.';

  @override
  String get editText => '텍스트 수정';

  @override
  String get deleteText => '삭제';

  @override
  String get deleteTextConfirm => '이 텍스트를 삭제할까요?';

  @override
  String get fontSize => '크기';

  @override
  String get textColor => '색상';

  @override
  String get textStyle => '스타일';

  @override
  String get textStyleCycle => '텍스트 스타일 변경';

  @override
  String get textTemplates => '워드아트';

  @override
  String get textTemplatePacks => '팩';

  @override
  String get textStudioTabTemplates => '텍스트';

  @override
  String get textStudioTabTextTemplates => '텍스트 템플릿';

  @override
  String get textStudioTabFonts => '글꼴';

  @override
  String get textStudioTabStyle => '스타일';

  @override
  String get textStudioTabEffects => '편집효과';

  @override
  String get textStudioTabAnimation => '애니메이션';

  @override
  String get textStudioTabBubbles => '거품';

  @override
  String get textStudioDefault => '기본';

  @override
  String get textPackSection => '텍스트 템플릿 서버';

  @override
  String get textPackUrlLabel => '팩 서버 URL';

  @override
  String get textPackUrlBody =>
      '워드아트 팩용 Vercel URL (catalog.json + Lottie). 비우면 앱 내장 팩만 사용합니다.';

  @override
  String get textPackUrlSaved => '팩 서버가 업데이트되었습니다.';

  @override
  String get textPackUrlSavePartial =>
      '저장했지만 원격 카탈로그에 연결하지 못했습니다. 내장 팩은 계속 사용할 수 있습니다.';

  @override
  String get timelineClip => '클립';

  @override
  String get timelineText => '텍스트 트랙';

  @override
  String get selectedText => '선택된 텍스트';

  @override
  String get noTextSelected => '텍스트 바를 탭하면 시간을 편집할 수 있습니다';

  @override
  String durationTotal(String duration) {
    return '전체 $duration';
  }

  @override
  String trimmedDuration(String duration) {
    return '클립 $duration';
  }

  @override
  String get save => '저장';

  @override
  String get exporting => '동영상 내보내는 중…';

  @override
  String get convertingVideo => '영상을 변환하는 중…';

  @override
  String get openingVideo => '영상을 여는 중…';

  @override
  String get exportSuccess => '갤러리에 저장했습니다.';

  @override
  String get exportFailed => '내보내기에 실패했습니다.';

  @override
  String exportFailedWithMessage(String message) {
    return '내보내기 실패: $message';
  }

  @override
  String get saveCancelled => '저장을 취소했습니다.';

  @override
  String get hideTimeline => '타임라인 숨기기';

  @override
  String get showTimeline => '타임라인 보기';

  @override
  String get resumeEditing => '이어서 편집';

  @override
  String resumeEditingSubtitle(int count, String updated) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '텍스트 $count개 · $updated 수정',
      zero: '텍스트 없음 · $updated 수정',
    );
    return '$_temp0';
  }

  @override
  String get draftBadge => '작성 중';

  @override
  String get startNewClip => '새 클립 만들기';

  @override
  String get exportShareHint => '공유한 뒤, 다음 클립을 만들러 돌아와 보세요.';

  @override
  String get pushDraftTitle => '클립을 이어서 완성하세요';

  @override
  String get pushDraftBody24 => '편집하던 프로젝트가 남아 있어요. EasyClip에서 이어서 작업해 보세요.';

  @override
  String get pushDraftBody72 => '아직 미완성이에요. 열고 내보내기만 하면 끝나요.';

  @override
  String get pushShareTitle => '올릴 준비 됐나요?';

  @override
  String get pushShareBody =>
      '내보낸 영상이 저장돼 있어요. YouTube·Instagram·TikTok으로 공유해 보세요.';

  @override
  String get pushCatalogTitle => '새 편집 도구';

  @override
  String get pushCatalogBody => '새로운 전환·텍스트 스타일이 추가됐어요. 다음 클립에 써 보세요.';

  @override
  String get projectsSection => '프로젝트';

  @override
  String get projectsEdit => '편집';

  @override
  String get projectsDone => '완료';

  @override
  String get deleteSelected => '삭제';

  @override
  String get noProjectsYet => '아직 프로젝트가 없습니다. 위에서 영상을 선택해 시작하세요.';

  @override
  String projectListSubtitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '텍스트 $count개',
      zero: '텍스트 없음',
    );
    return '$_temp0';
  }

  @override
  String get deleteProject => '프로젝트 삭제';

  @override
  String get deleteProjectConfirm => '이 프로젝트를 삭제할까요? 되돌릴 수 없습니다.';

  @override
  String deleteProjectsConfirm(int count) {
    return '프로젝트 $count개를 삭제할까요? 되돌릴 수 없습니다.';
  }

  @override
  String get projectNotFound => '저장된 프로젝트를 찾을 수 없습니다.';

  @override
  String get settingsTitle => '설정';

  @override
  String get exportQualitySection => '보내기 품질';

  @override
  String get exportQualityRecommendedTitle => '권장';

  @override
  String get exportQualityRecommendedBody =>
      '1080p 상한, 업스케일 없음. 트림만 했을 때는 원본 스트림 복사 (CapCut 기본과 유사).';

  @override
  String get exportQualityHighTitle => '고화질';

  @override
  String get exportQualityHighBody => '최고 디테일 (CRF 18). 항상 재인코딩하며 시간이 더 걸립니다.';

  @override
  String get exportQualitySmallerTitle => '작은 파일';

  @override
  String get exportQualitySmallerBody => '빠르고 용량이 작습니다. 트림만 했을 때는 원본 스트림 복사.';

  @override
  String get exportQualityOriginalTitle => '원본 유지';

  @override
  String get exportQualityOriginalBody =>
      '가능하면 원본 비트스트림을 그대로 사용합니다. 텍스트·회전이 있을 때만 가볍게 인코딩.';

  @override
  String get addMusic => '음악 추가';

  @override
  String get recordVoice => '녹음';

  @override
  String get startVoiceRecording => '녹음 시작';

  @override
  String get stopVoiceRecording => '정지';

  @override
  String get voiceRecordingTitle => '녹음';

  @override
  String get voiceRecordPermissionDenied => '녹음하려면 마이크 권한이 필요합니다.';

  @override
  String get voiceRecordTooShort => '녹음이 너무 짧습니다.';

  @override
  String get voiceRecordFailed => '녹음을 저장하지 못했습니다.';

  @override
  String get importMusicFile => '오디오 파일 가져오기';

  @override
  String get searchMusicHint => '저작권 없는 음악 검색';

  @override
  String get searchSfxHint => '사운드 효과 검색';

  @override
  String get musicTabMusic => '음악';

  @override
  String get musicTabSfx => '효과음';

  @override
  String get musicGenreAll => '전체';

  @override
  String get musicGenreTravel => '여행';

  @override
  String get musicGenreBeauty => '뷰티';

  @override
  String get musicGenreFashion => '패션';

  @override
  String get musicGenreHappy => '신나는';

  @override
  String get musicGenreEnergetic => '에너지';

  @override
  String get musicGenreChill => '잔잔한';

  @override
  String get musicGenreCinematic => '시네마틱';

  @override
  String get musicGenreRomantic => '로맨틱';

  @override
  String get musicGenreSports => '스포츠';

  @override
  String get musicGenreNature => '자연';

  @override
  String get musicGenreCooking => '요리';

  @override
  String get musicGenreCorporate => '비즈니스';

  @override
  String get musicGenreHipHop => '힙합';

  @override
  String get musicGenrePop => '팝';

  @override
  String get musicGenreKids => '키즈';

  @override
  String get sfxGenreWhoosh => '우시';

  @override
  String get sfxGenreTransition => '전환';

  @override
  String get sfxGenreImpact => '임팩트';

  @override
  String get sfxGenreGlitch => '글리치';

  @override
  String get sfxGenreNotification => '알림';

  @override
  String get sfxGenreGame => '게임';

  @override
  String get sfxGenreTech => '테크';

  @override
  String get sfxGenreUi => 'UI';

  @override
  String get musicCatalogAttribution =>
      '상업 이용 가능 · 저작자 표시 불필요 (Pixabay / Mixkit).';

  @override
  String get musicCatalogUnavailable =>
      '음악 카탈로그를 불러오지 못했습니다. 파일을 가져오거나 텍스트 템플릿 서버 주소를 확인하세요.';

  @override
  String get musicLocalOnlyHint => '기기에서 MP3, M4A, WAV 파일을 가져오세요.';

  @override
  String get musicNoResults => '검색 결과가 없습니다.';

  @override
  String musicImportFailed(String message) {
    return '음악을 추가하지 못했습니다: $message';
  }

  @override
  String get useMusicTrack => '사용';

  @override
  String get musicPreviewFailed => '미리듣기를 재생할 수 없습니다.';

  @override
  String get removeMusic => '음악 제거';

  @override
  String get retry => '다시 시도';

  @override
  String get musicCatalogSection => '음악 카탈로그';

  @override
  String get musicCatalogReady => 'Pixabay Music';

  @override
  String get musicCatalogBody => '상업 이용 가능 · 저작자 표시 불필요 (Pixabay / Mixkit).';

  @override
  String get splitVideo => '분할';

  @override
  String get transition => '전환';

  @override
  String get transitionSheetTitle => '전환 효과';

  @override
  String get transitionSheetSubtitle => '재생 위치에서 가장 가까운 컷에 적용됩니다.';

  @override
  String get transitionNone => '없음';

  @override
  String get transitionCatalogUnavailable => '전환 효과를 불러올 수 없습니다.';

  @override
  String get transitionApplied => '전환이 적용되었습니다.';

  @override
  String get transitionNeedsCuts => '전환을 추가하려면 먼저 클립을 분할하세요.';

  @override
  String get transitionDuration => '길이';

  @override
  String get deleteSegment => '구간 삭제';

  @override
  String get splitOutOfRange => '재생 위치를 클립 안으로 옮긴 뒤 분할하세요.';

  @override
  String get splitTooShort => '각 구간은 최소 1초 이상이어야 합니다.';

  @override
  String get splitFailed => '클립을 분할하지 못했습니다.';

  @override
  String splitSuccess(String time) {
    return '$time에서 분할됨';
  }

  @override
  String get cannotDeleteLastSegment => '최소 한 개의 클립 구간은 남겨야 합니다.';

  @override
  String get undo => '실행 취소';

  @override
  String get redo => '다시 실행';

  @override
  String get uploadVisibility => '공개 범위';

  @override
  String get uploadThumbnail => '썸네일';

  @override
  String get uploadThumbnailSelect => '썸네일 선택';

  @override
  String get uploadThumbnailAuto => '자동';

  @override
  String get uploadThumbnailFromPhoto => '사진에서 선택';

  @override
  String get uploadPlaylist => '재생목록';

  @override
  String get uploadPlaylistNone => '재생목록에 넣지 않음';

  @override
  String get uploadPlaylistLoad => '재생목록 불러오기';

  @override
  String get uploadPlaylistEmpty => '이 채널에 재생목록이 없습니다.';

  @override
  String get uploadPlaylistFailed => '재생목록을 불러오지 못했습니다.';

  @override
  String get uploadAudience => '시청자층';

  @override
  String get uploadAudienceNotForKids => '아동용이 아님';

  @override
  String get uploadAudienceForKids => '아동용';

  @override
  String get uploadAudienceHelp => 'YouTube에 필수로 알려야 합니다. 아동용은 기능이 제한됩니다.';

  @override
  String get uploadAgeRestriction => '연령 제한';

  @override
  String get uploadAgeRestrictionHelp =>
      '18세 이상만 시청할 수 있습니다. 아동용이면 사용할 수 없습니다.';

  @override
  String get uploadMoreDetails => '더보기';

  @override
  String get uploadFewerDetails => '간략히 보기';

  @override
  String get uploadShortsCaption => '동영상 설명 추가';

  @override
  String get uploadLocation => '위치';

  @override
  String get uploadLocationHint => '장소 이름';

  @override
  String get uploadLocationNotFound => '위치를 찾지 못했습니다.';

  @override
  String get uploadRelatedVideo => '관련 동영상';

  @override
  String get uploadRelatedVideoHint => 'YouTube 링크 또는 영상 ID';

  @override
  String get uploadRelatedVideoInvalid => '관련 동영상 주소를 확인해 주세요.';

  @override
  String get uploadPaidPromotion => '유료 프로모션 및 브랜드';

  @override
  String get uploadPaidPromotionHelp =>
      '유료 제품 배치가 있으면 켜세요. 업로드할 때 YouTube에 표시됩니다.';

  @override
  String get uploadAlteredContent => 'AI 사용';

  @override
  String get uploadAlteredContentHelp => '실제처럼 보이게 바꾼 합성 영상이면 켜세요.';

  @override
  String get uploadTags => '태그';

  @override
  String get uploadTagsHint => '쉼표로 구분';

  @override
  String get exportComplete => '내보내기 완료';

  @override
  String get savedToDevice => '장치에 저장됨';

  @override
  String get shareContentTitle => '컨텐츠 공유';

  @override
  String get shareMyContent => '내 컨텐츠 공유';

  @override
  String get sharePickFromAlbumHint => '앨범에서 영상을 골라 공유하세요.';

  @override
  String get share => '공유';

  @override
  String shareAppMessage(String url) {
    return 'EasyClip으로 짧은 영상을 빠르게 편집해 보세요.\n$url';
  }

  @override
  String get exportDone => '완료';

  @override
  String get shareToYouTube => 'YouTube';

  @override
  String get shareMore => '기타';

  @override
  String get shareAppMissing => '해당 앱이 설치되어 있지 않습니다.';

  @override
  String get shareFacebookOpened => '목록에서 Facebook을 선택해 게시를 완료하세요.';

  @override
  String get shareFacebookPosted => 'Facebook에 게시했어요';

  @override
  String get shareFacebookCancelled => 'Facebook 게시를 취소했습니다.';

  @override
  String shareFacebookFailed(String message) {
    return 'Facebook에 게시하지 못했어요. $message';
  }

  @override
  String uploadPartialFailure(String videoId, String message) {
    return '영상은 업로드되었습니다 ($videoId). 다음 단계가 실패했습니다: $message';
  }

  @override
  String get canvasRatio => '비율';

  @override
  String get canvasRatioOriginal => '원본';

  @override
  String get textColorCustom => '직접 선택';

  @override
  String get textColorDone => '완료';

  @override
  String get overlayFontBasic => '기본';

  @override
  String get overlayFontNotoSans => '노토 산스';

  @override
  String get overlayFontGaegu => '개구';

  @override
  String get overlayFontBlackHan => '블랙한';

  @override
  String get overlayFontDoHyeon => '도현';

  @override
  String get overlayFontGothicA1 => '고딕 A1';

  @override
  String get overlayFontRoboto => '로보토';

  @override
  String get overlayFontJua => '주아';

  @override
  String get overlayFontBagelFat => '베이글';

  @override
  String get overlayFontSongMyung => '송명';

  @override
  String get overlayFontHiMelody => '하이멜로디';

  @override
  String get overlayFontStylish => '스타일리시';

  @override
  String get overlayFontNanumPen => '나눔손글씨';

  @override
  String get overlayFontGasoek => '가석';

  @override
  String get overlayFontCycleHint => '글꼴 변경';

  @override
  String get textFont => 'Font';

  @override
  String projectDefaultName(int n) {
    return '프로젝트 $n';
  }

  @override
  String get projectNameTitle => '프로젝트 이름';

  @override
  String get projectNameHint => '프로젝트 이름을 입력하세요';

  @override
  String proTitle(String appName) {
    return '$appName Pro';
  }

  @override
  String get proSubtitle => '모든 효과를 풀고 더 돋보이는 클립을 만드세요.';

  @override
  String get proBenefitEffects => '모든 Pro 전환·텍스트 효과';

  @override
  String get proBenefitNoAds => '광고 없이 저장';

  @override
  String get proBenefitFuture => '새로 추가되는 Pro 기능';

  @override
  String get proSubscribe => 'Pro 시작하기';

  @override
  String get proRestore => '구매 복원';

  @override
  String get proAnnualBadge => '가장 저렴';

  @override
  String get proLegal => '구독은 자동으로 갱신되며, 스토어 계정 설정에서 언제든 해지할 수 있어요.';

  @override
  String get proStoreUnavailable => '아직 스토어가 연결되지 않았어요.';

  @override
  String get proDebugToggle => '테스트용 Pro (디버그 전용)';

  @override
  String get proActive => 'Pro 사용 중';

  @override
  String planActive(String plan) {
    return '$plan 사용 중';
  }

  @override
  String planActiveWithPeriod(String plan, String period) {
    return '$plan · $period 사용 중';
  }

  @override
  String get planCurrentSubscription => '현재 구독 중';

  @override
  String get planSwitchToAnnual => '연간으로 전환';

  @override
  String get planSwitchToMonthly => '월간으로 전환';

  @override
  String planUpgradeCta(String plan) {
    return '$plan으로 업그레이드';
  }

  @override
  String planDowngradeCta(String plan) {
    return '$plan으로 변경';
  }

  @override
  String planDowngradeHint(String current) {
    return '현재 결제 기간이 끝난 뒤에 적용됩니다. 그전까지는 $current이(가) 유지됩니다.';
  }

  @override
  String get planPeriodDowngradeBlocked => '연간에서 월간으로 바꾸려면 스토어에서 구독을 관리하세요.';

  @override
  String get planManageSubscription => '구독 관리';

  @override
  String get planUpgradeBadge => '업그레이드';

  @override
  String get planDowngradeBadge => '갱신 시 적용';

  @override
  String planUpgradeSheetTitle(String plan) {
    return '$plan으로 업그레이드';
  }

  @override
  String get planUpgradeToday => '오늘';

  @override
  String get planUpgradeAfter => '업그레이드 후';

  @override
  String get planUpgradeContinue => '계속';

  @override
  String get planUpgradeLegal =>
      '계속하면 요금제가 바로 업그레이드되고 오늘 결제됩니다. 남은 기간은 스토어에서 차감·정산됩니다. 다음 갱신부터는 새 요금이 적용됩니다.';

  @override
  String planUpgradePriceDetail(String plan, String price, String period) {
    return '$plan, $price · $period';
  }

  @override
  String get proInactive => '무료 플랜';

  @override
  String get proPurchaseFailed => '결제가 완료되지 않았어요. 다시 시도해 주세요.';

  @override
  String get proRestoreNone => '복원할 구매 내역이 없어요.';

  @override
  String get proSection => '구독';

  @override
  String get premiumExportTitle => '유료 효과가 들어 있어요';

  @override
  String get premiumExportBody => '효과마다 광고를 보거나, 구독으로 한 번에 잠금 해제하세요.';

  @override
  String get premiumExportWithPro => '구독하고 전부 잠금 해제';

  @override
  String get premiumExportWatchAd => '광고 보고 사용';

  @override
  String premiumExportWatchAdsCount(int count, int credits) {
    return '광고 $count회 보기 (크레딧 $credits)';
  }

  @override
  String premiumExportSpendCredits(int credits, int balance) {
    return '크레딧 $credits 사용 (잔액 $balance)';
  }

  @override
  String premiumExportCreditCost(int credits, int balance) {
    return '이 내보내기는 크레딧 $credits이 필요합니다. 잔액: $balance.';
  }

  @override
  String get premiumExportStrip => '잠긴 효과 빼고 저장';

  @override
  String get premiumExportEffectUnlocked => '사용 가능';

  @override
  String get premiumExportContinue => '이어서 저장';

  @override
  String get premiumAdNotFinished => '광고를 끝까지 봐야 이 효과를 쓸 수 있어요.';

  @override
  String get premiumCreditsSpendFailed => '크레딧이 부족합니다. 광고를 더 보거나 구독하세요.';

  @override
  String get loginRequiredForSubscribe => '구독하려면 로그인해 주세요.';

  @override
  String get accountSection => '계정';

  @override
  String get accountSignIn => '로그인';

  @override
  String get accountSignOut => '로그아웃';

  @override
  String accountSignedInAs(String name) {
    return '$name으로 로그인됨';
  }

  @override
  String creditsBalanceLabel(int balance) {
    return '크레딧 $balance';
  }

  @override
  String get planPlusLabel => 'Plus';

  @override
  String get planProLabel => 'Pro';

  @override
  String get planStudioLabel => 'Studio';

  @override
  String get planBillingMonthly => '월간';

  @override
  String get planBillingAnnual => '연간';

  @override
  String get planAnnualSaveBadge => '연간 구독하면 2개월 무료';

  @override
  String planPlusTitle(String appName) {
    return '$appName Plus';
  }

  @override
  String planProTitle(String appName) {
    return '$appName Pro';
  }

  @override
  String planStudioTitle(String appName) {
    return '$appName Studio';
  }

  @override
  String planPlusSubtitle(int credits) {
    return '매월 크레딧 $credits으로 프리미엄 효과를 쓰세요.';
  }

  @override
  String planProSubtitle(int credits) {
    return '매월 크레딧 $credits과 AI 도구를 함께.';
  }

  @override
  String planStudioSubtitle(int credits) {
    return '헤비 크리에이터용 매월 크레딧 $credits.';
  }

  @override
  String planPlusBenefit1(int credits) {
    return '매월 크레딧 $credits 지급';
  }

  @override
  String get planPlusBenefit2 => '모든 프리미엄 전환·텍스트 효과';

  @override
  String get planPlusBenefit3 => '저장 시 크레딧 사용 · 부족하면 광고로 충전';

  @override
  String planProBenefit1(int credits) {
    return '매월 크레딧 $credits 지급';
  }

  @override
  String get planProBenefit2 => '모든 프리미엄 전환·텍스트 효과';

  @override
  String get planProBenefit3 => 'AI 도구 사용';

  @override
  String get planProBenefit4 => '저장 시 크레딧 사용 · 부족하면 광고로 충전';

  @override
  String planStudioBenefit1(int credits) {
    return '매월 크레딧 $credits 지급';
  }

  @override
  String get planStudioBenefit2 => '모든 프리미엄 전환·텍스트 효과';

  @override
  String get planStudioBenefit3 => 'AI 도구 사용';

  @override
  String get planStudioBenefit4 => 'Studio 크리에이티브 추가 기능과 새 도구 우선 이용';

  @override
  String get planStudioBenefit5 => '저장 시 크레딧 사용 · 부족하면 광고로 충전';

  @override
  String planSubscribeCta(String plan) {
    return '$plan 구독하기';
  }

  @override
  String get planChooseTitle => '요금제 선택';

  @override
  String get planCompareTitle => '요금제 비교';

  @override
  String get planComparePlusEffects => 'Plus 효과';

  @override
  String get planCompareProEffects => 'Pro 효과';

  @override
  String get planCompareAi => 'AI 도구';

  @override
  String get planCompareCredits => '월 AI 크레딧';

  @override
  String get planCompareStudioExtras => 'Studio 추가 기능';

  @override
  String get proBenefitAi => 'Pro·Studio에서 AI 도구 사용';

  @override
  String get uploadAccountTitle => '업로드할 YouTube 계정';

  @override
  String get uploadAccountNone => '아직 연결된 계정이 없어요';

  @override
  String get uploadAccountConnect => '계정 연결';

  @override
  String get uploadAccountSwitch => '계정 변경';

  @override
  String get uploadErrorTitle => '업로드하지 못했어요';

  @override
  String get uploadErrSuspended =>
      '이 Google 계정의 YouTube 채널이 정지되어 영상을 올릴 수 없어요. 다른 계정으로 로그인해 주세요.';

  @override
  String get uploadErrNoChannel =>
      '이 Google 계정에는 아직 YouTube 채널이 없어요. YouTube 앱에서 채널을 만든 뒤 다시 시도하거나, 다른 계정으로 로그인해 주세요.';

  @override
  String get uploadErrUploadLimit =>
      '이 채널은 오늘 올릴 수 있는 영상 수를 모두 썼어요. 24시간 뒤에 다시 시도해 주세요.';

  @override
  String get uploadErrQuota =>
      '지금은 YouTube 업로드 요청이 많아 처리하지 못했어요. 잠시 후 다시 시도해 주세요.';

  @override
  String get uploadErrAuth => '로그인이 만료됐어요. 다시 로그인해 주세요.';

  @override
  String get uploadErrPermission => 'YouTube 업로드 권한을 허용해야 영상을 올릴 수 있어요.';

  @override
  String get uploadErrNetwork => '인터넷 연결이 불안정해요. 연결을 확인하고 다시 시도해 주세요.';

  @override
  String get uploadErrUnknown => '잠시 후 다시 시도해 주세요. 문제가 계속되면 아래 코드를 알려 주세요.';

  @override
  String uploadErrCode(String code) {
    return '오류 코드: $code';
  }

  @override
  String get uploadSwitchAccountAction => '다른 계정으로 로그인';

  @override
  String uploadPartialDone(String steps) {
    return '영상은 올라갔지만 다음 설정은 적용하지 못했어요: $steps. YouTube 스튜디오에서 직접 바꿀 수 있어요.';
  }

  @override
  String get uploadStepThumbnail => '썸네일';

  @override
  String get uploadStepPlaylist => '재생목록';

  @override
  String get uploadStepAgeRestriction => '연령 제한';

  @override
  String get uploadStepLocation => '위치';

  @override
  String get uploadOk => '확인';

  @override
  String get uploadDoneTitle => 'YouTube에 올렸어요';

  @override
  String get uploadDoneProcessing =>
      'YouTube에서 처리하는 데 몇 분 걸릴 수 있어서 바로 재생되지 않을 수 있어요.';

  @override
  String uploadDoneVisibility(String visibility) {
    return '공개 범위: $visibility';
  }

  @override
  String get uploadDoneOpen => 'YouTube에서 보기';

  @override
  String get uploadDoneCopy => '링크 복사';

  @override
  String get uploadDoneCopied => '링크를 복사했어요';

  @override
  String get uploadDoneShare => '공유';

  @override
  String get uploadDoneClose => '완료';

  @override
  String shareAppPosted(String app) {
    return '$app에 올렸어요';
  }

  @override
  String shareAppCancelled(String app) {
    return '$app 게시를 취소했어요.';
  }

  @override
  String shareAppFailed(String app, String message) {
    return '$app에 올리지 못했어요. $message';
  }

  @override
  String get tiktokUploadTitle => 'TikTok에 올리기';

  @override
  String get tiktokAccountTitle => '올릴 TikTok 계정';

  @override
  String get tiktokCaptionHint => '설명, #해시태그, @멘션';

  @override
  String get tiktokPrivacyChoose => '공개 범위를 선택하세요';

  @override
  String get tiktokPrivacyPublic => '전체 공개';

  @override
  String get tiktokPrivacyFriends => '친구 (서로 팔로우)';

  @override
  String get tiktokPrivacyFollowers => '팔로워';

  @override
  String get tiktokPrivacySelf => '나만 보기';

  @override
  String get tiktokInteractionTitle => '다른 사람이 할 수 있는 것';

  @override
  String get tiktokAllowComment => '댓글';

  @override
  String get tiktokAllowDuet => '듀엣';

  @override
  String get tiktokAllowStitch => '스티치';

  @override
  String get tiktokInteractionOff => 'TikTok 설정에서 꺼져 있어요';

  @override
  String get tiktokDisclose => '콘텐츠 공개';

  @override
  String get tiktokDiscloseHelp => '상품, 브랜드, 서비스를 홍보하는 영상이면 켜세요.';

  @override
  String get tiktokYourBrand => '내 브랜드';

  @override
  String get tiktokYourBrandHelp => '본인이나 내 사업을 홍보해요. \'홍보 콘텐츠\'로 표시돼요.';

  @override
  String get tiktokBrandedContent => '브랜드 콘텐츠';

  @override
  String get tiktokBrandedContentHelp =>
      '다른 브랜드나 제3자를 홍보해요. \'유료 파트너십\'으로 표시돼요.';

  @override
  String get tiktokDiscloseNeedOne => '하나 이상 선택해야 게시할 수 있어요.';

  @override
  String get tiktokBrandedNotPrivate => '브랜드 콘텐츠는 \'나만 보기\'로 올릴 수 없어요.';

  @override
  String tiktokConsent(String policies) {
    return '게시하면 TikTok의 $policies에 동의하게 됩니다.';
  }

  @override
  String get tiktokMusicPolicy => '음악 사용 확인';

  @override
  String get tiktokBrandPolicy => '브랜드 콘텐츠 정책';

  @override
  String get tiktokAnd => ' 및 ';

  @override
  String get tiktokPost => '게시';

  @override
  String get tiktokPostAndYouTube => 'TikTok·YouTube에 게시';

  @override
  String tiktokUploading(int percent) {
    return '업로드 중 $percent%';
  }

  @override
  String get tiktokProcessing => 'TikTok에서 처리 중…';

  @override
  String youtubeExporting(int percent) {
    return '준비 중 $percent%';
  }

  @override
  String youtubeUploading(int percent) {
    return '업로드 중 $percent%';
  }

  @override
  String get youtubeFinishing => '마무리 중…';

  @override
  String crossPostUploadingYouTube(int percent) {
    return 'YouTube $percent%';
  }

  @override
  String crossPostUploadingTikTok(int percent) {
    return 'TikTok $percent%';
  }

  @override
  String get crossPostProcessingTikTok => 'TikTok에서 처리 중…';

  @override
  String get tiktokDoneTitle => 'TikTok에 올렸어요';

  @override
  String get tiktokDoneProcessing => '프로필에 나타나기까지 몇 분 걸릴 수 있어요.';

  @override
  String get tiktokOpen => 'TikTok에서 보기';

  @override
  String get tiktokFinishInApp => 'TikTok 앱에서 마무리하기';

  @override
  String tiktokTooLong(int max) {
    return '이 계정은 $max초까지 올릴 수 있어요.';
  }

  @override
  String get tiktokConnectHelp => 'TikTok 계정을 연결하면 여기서 바로 올릴 수 있어요.';

  @override
  String get tiktokErrServer => 'TikTok 연결 설정이 아직 끝나지 않았어요. 잠시 후 다시 시도해 주세요.';

  @override
  String get tiktokErrDenied => 'TikTok 게시 권한을 허용해야 올릴 수 있어요.';

  @override
  String get tiktokErrAuth => 'TikTok 로그인이 만료됐어요. 다시 연결해 주세요.';

  @override
  String get tiktokErrPrivateOnly =>
      'EasyClip이 TikTok 심사를 통과하기 전에는 비공개 계정에서만 올릴 수 있어요. TikTok 앱 → 설정 및 개인정보 → 개인정보에서 \'비공개 계정\'을 켠 뒤 다시 시도해 주세요.';

  @override
  String get tiktokErrSpam => 'TikTok이 지금은 게시를 제한했어요. 나중에 다시 시도해 주세요.';

  @override
  String get tiktokErrBanned => '이 TikTok 계정은 지금 게시할 수 없어요. 다른 계정으로 연결해 주세요.';

  @override
  String get tiktokErrPrivacyMismatch =>
      '이 계정에서는 그 공개 범위를 쓸 수 없어요. 다른 범위를 선택해 주세요.';

  @override
  String get tiktokErrFailed => 'TikTok이 영상을 처리하지 못했어요.';

  @override
  String get tiktokSwitchAccount => '다른 계정으로 연결';
}
