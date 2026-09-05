// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Korean (`ko`).
class AppLocalizationsKo extends AppLocalizations {
  AppLocalizationsKo([String locale = 'ko']) : super(locale);

  @override
  String get appTitle => 'AVEditor';

  @override
  String get homeTagline => '텍스트는 원하는 구간에만 — Shorts 업로드까지 한 앱에서.';

  @override
  String get pickFromGallery => '갤러리에서 선택';

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
  String get rotateVideo => '영상 회전';

  @override
  String get export => '내보내기';

  @override
  String get uploadShorts => 'Shorts 업로드';

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
  String get permissionPhotosDenied => '사진 라이브러리 접근이 꺼져 있습니다. 설정에서 허용해 주세요.';

  @override
  String get permissionCameraDenied => '카메라 접근이 꺼져 있습니다. 설정에서 허용해 주세요.';

  @override
  String get openSettings => '설정';

  @override
  String get comingSoon => '준비 중';

  @override
  String get trimStart => '시작 지점';

  @override
  String get trimEnd => '끝 지점';

  @override
  String get textOverlayHint => '텍스트 입력';

  @override
  String get uploadTitleHint => 'Shorts 제목';

  @override
  String get uploadDescriptionHint => '설명 (#Shorts 권장)';

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
  String get projectsSection => '프로젝트';

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
  String get musicCatalogBody =>
      '상업 이용 가능, 저작자 표시 불필요. 서버에 PIXABAY_API_KEY가 있으면 Pixabay Music, 없으면 Mixkit으로 검색합니다.';

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
}
