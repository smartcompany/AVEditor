// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get appTitle => 'AVEditor';

  @override
  String get homeTagline => 'テキストは指定区間だけ — Shorts投稿までこのアプリで。';

  @override
  String get pickFromGallery => 'ギャラリーから選択';

  @override
  String get pickFromFiles => '動画ファイルを選択';

  @override
  String get recordVideo => '動画を撮影';

  @override
  String get youtubeSignIn => 'YouTubeにログイン';

  @override
  String get youtubeSignedIn => 'YouTube接続済み';

  @override
  String get youtubeSignOut => 'ログアウト';

  @override
  String get editorTitle => '編集';

  @override
  String get addText => 'テキストを追加';

  @override
  String get export => '書き出し';

  @override
  String get uploadShorts => 'Shortsをアップロード';

  @override
  String get saveToGallery => 'ギャラリーに保存';

  @override
  String get cancel => 'キャンセル';

  @override
  String get videoNotSelected => '動画が選択されていません。';

  @override
  String videoPickError(String message) {
    return '動画を開けませんでした: $message';
  }

  @override
  String get permissionPhotosDenied => '写真ライブラリへのアクセスがオフです。設定で許可してください。';

  @override
  String get permissionCameraDenied => 'カメラへのアクセスがオフです。設定で許可してください。';

  @override
  String get openSettings => '設定';

  @override
  String get comingSoon => '準備中';

  @override
  String get trimStart => '開始位置';

  @override
  String get trimEnd => '終了位置';

  @override
  String get textOverlayHint => 'テキストを入力';

  @override
  String get uploadTitleHint => 'Shortsタイトル';

  @override
  String get uploadDescriptionHint => '説明（#Shorts推奨）';

  @override
  String get privacyPublic => '公開';

  @override
  String get privacyUnlisted => '限定公開';

  @override
  String get privacyPrivate => '非公開';

  @override
  String get videoLoadError => '動画を読み込めませんでした。';

  @override
  String get editText => 'テキストを編集';

  @override
  String get deleteText => '削除';

  @override
  String get fontSize => 'サイズ';

  @override
  String get textColor => '色';

  @override
  String get timelineClip => 'クリップ';

  @override
  String get timelineText => 'テキストトラック';

  @override
  String get selectedText => '選択中のテキスト';

  @override
  String get noTextSelected => 'テキストバーをタップして時間を編集';

  @override
  String durationTotal(String duration) {
    return '全体 $duration';
  }

  @override
  String trimmedDuration(String duration) {
    return 'クリップ $duration';
  }

  @override
  String get save => '保存';

  @override
  String get exporting => '動画を書き出し中…';

  @override
  String get exportSuccess => 'ライブラリに保存しました。';

  @override
  String get exportFailed => '書き出しに失敗しました。';

  @override
  String exportFailedWithMessage(String message) {
    return '書き出し失敗: $message';
  }

  @override
  String get saveCancelled => '保存をキャンセルしました。';
}
