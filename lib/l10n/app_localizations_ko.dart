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
  String get export => '내보내기';

  @override
  String get uploadShorts => 'Shorts 업로드';

  @override
  String get saveToGallery => '갤러리에 저장';

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
}
