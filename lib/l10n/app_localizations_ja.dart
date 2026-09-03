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
  String get rotateVideo => '動画を回転';

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
  String get textStyle => 'スタイル';

  @override
  String get textStyleCycle => 'テキストスタイルを切り替え';

  @override
  String get textTemplates => 'ワードアート';

  @override
  String get textTemplatePacks => 'パック';

  @override
  String get textPackSection => 'テキストテンプレートサーバー';

  @override
  String get textPackUrlLabel => 'パックのベース URL';

  @override
  String get textPackUrlBody =>
      'ワードアート用の Vercel URL（catalog.json + Lottie）。空欄なら内蔵パックのみです。';

  @override
  String get textPackUrlSaved => 'パックサーバーを更新しました。';

  @override
  String get textPackUrlSavePartial =>
      '保存しましたが、リモートカタログに接続できませんでした。内蔵パックは利用できます。';

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

  @override
  String get hideTimeline => 'タイムラインを隠す';

  @override
  String get showTimeline => 'タイムラインを表示';

  @override
  String get resumeEditing => '編集を再開';

  @override
  String resumeEditingSubtitle(int count, String updated) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'テキスト $count件 · $updated 更新',
      zero: 'テキストなし · $updated 更新',
    );
    return '$_temp0';
  }

  @override
  String get projectNotFound => '保存されたプロジェクトが見つかりません。';

  @override
  String get settingsTitle => '設定';

  @override
  String get exportQualitySection => '書き出し品質';

  @override
  String get exportQualityRecommendedTitle => 'おすすめ';

  @override
  String get exportQualityRecommendedBody =>
      '1080p上限・アップスケールなし。トリムのみのときはストリームコピー（CapCutの既定に近い）。';

  @override
  String get exportQualityHighTitle => '高画質';

  @override
  String get exportQualityHighBody => '最高のディテール（CRF 18）。常に再エンコードし、時間がかかります。';

  @override
  String get exportQualitySmallerTitle => '小さいファイル';

  @override
  String get exportQualitySmallerBody => '高速でファイルサイズが小さい。トリムのみのときはストリームコピー。';

  @override
  String get exportQualityOriginalTitle => 'オリジナルに合わせる';

  @override
  String get exportQualityOriginalBody =>
      '可能なら元のビットストリームを維持。テキストや回転があるときだけ軽くエンコード。';

  @override
  String get addMusic => '音楽を追加';

  @override
  String get importMusicFile => 'オーディオファイルを読み込む';

  @override
  String get searchMusicHint => '著作権フリー音楽を検索';

  @override
  String get musicCatalogAttribution => '商用利用可・クレジット不要（Pixabay / Mixkit）。';

  @override
  String get musicCatalogUnavailable =>
      '音楽カタログを読み込めません。ファイルを読み込むか、テキストテンプレートサーバーのURLを確認してください。';

  @override
  String get musicLocalOnlyHint => '端末から MP3、M4A、WAV ファイルを読み込んでください。';

  @override
  String get musicNoResults => '曲が見つかりません。';

  @override
  String musicImportFailed(String message) {
    return '音楽を追加できませんでした: $message';
  }

  @override
  String get useMusicTrack => '使う';

  @override
  String get musicPreviewFailed => 'プレビューを再生できません。';

  @override
  String get removeMusic => '音楽を削除';

  @override
  String get retry => '再試行';

  @override
  String get musicCatalogSection => '音楽カタログ';

  @override
  String get musicCatalogReady => 'Pixabay Music';

  @override
  String get musicCatalogBody =>
      '商用利用可・クレジット不要。サーバーに PIXABAY_API_KEY があれば Pixabay Music、なければ Mixkit で検索します。';

  @override
  String get splitVideo => '分割';

  @override
  String get deleteSegment => 'セグメントを削除';

  @override
  String get splitOutOfRange => 'クリップ内に再生位置を移動してから分割してください。';

  @override
  String get splitTooShort => '各パートは少なくとも1秒必要です。';

  @override
  String get splitFailed => 'クリップを分割できませんでした。';

  @override
  String splitSuccess(String time) {
    return '$time で分割しました';
  }

  @override
  String get cannotDeleteLastSegment => '少なくとも1つのクリップ区間が必要です。';

  @override
  String get undo => '元に戻す';

  @override
  String get redo => 'やり直す';
}
