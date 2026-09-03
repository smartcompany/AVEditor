// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'AVEditor';

  @override
  String get homeTagline => '文字只在指定时段出现 — 一个应用完成 Shorts 上传。';

  @override
  String get pickFromGallery => '从相册选择';

  @override
  String get pickFromFiles => '选择视频文件';

  @override
  String get recordVideo => '拍摄视频';

  @override
  String get youtubeSignIn => 'YouTube 登录';

  @override
  String get youtubeSignedIn => '已连接 YouTube';

  @override
  String get youtubeSignOut => '退出登录';

  @override
  String get editorTitle => '编辑';

  @override
  String get addText => '添加文字';

  @override
  String get rotateVideo => '旋转视频';

  @override
  String get export => '导出';

  @override
  String get uploadShorts => '上传 Shorts';

  @override
  String get saveToGallery => '保存到相册';

  @override
  String get cancel => '取消';

  @override
  String get videoNotSelected => '未选择视频。';

  @override
  String videoPickError(String message) {
    return '无法打开视频：$message';
  }

  @override
  String get permissionPhotosDenied => '照片库访问已关闭，请在设置中开启。';

  @override
  String get permissionCameraDenied => '相机访问已关闭，请在设置中开启。';

  @override
  String get openSettings => '设置';

  @override
  String get comingSoon => '即将推出';

  @override
  String get trimStart => '修剪起点';

  @override
  String get trimEnd => '修剪终点';

  @override
  String get textOverlayHint => '输入文字';

  @override
  String get uploadTitleHint => 'Shorts 标题';

  @override
  String get uploadDescriptionHint => '描述（建议含 #Shorts）';

  @override
  String get privacyPublic => '公开';

  @override
  String get privacyUnlisted => '不公开列出';

  @override
  String get privacyPrivate => '私密';

  @override
  String get videoLoadError => '无法加载视频。';

  @override
  String get editText => '编辑文字';

  @override
  String get deleteText => '删除';

  @override
  String get fontSize => '大小';

  @override
  String get textColor => '颜色';

  @override
  String get textStyle => '样式';

  @override
  String get textStyleCycle => '切换文字样式';

  @override
  String get textTemplates => '艺术字';

  @override
  String get textTemplatePacks => '素材包';

  @override
  String get textPackSection => '文字模板服务器';

  @override
  String get textPackUrlLabel => '素材包基础 URL';

  @override
  String get textPackUrlBody =>
      '用于艺术字素材包的 Vercel 地址（catalog.json + Lottie）。留空则仅使用内置素材。';

  @override
  String get textPackUrlSaved => '素材包服务器已更新。';

  @override
  String get textPackUrlSavePartial => '已保存，但无法连接远程目录。内置素材仍可用。';

  @override
  String get timelineClip => '片段';

  @override
  String get timelineText => '文字轨道';

  @override
  String get selectedText => '选中的文字';

  @override
  String get noTextSelected => '点击文字条可编辑时间';

  @override
  String durationTotal(String duration) {
    return '全长 $duration';
  }

  @override
  String trimmedDuration(String duration) {
    return '片段 $duration';
  }

  @override
  String get save => '保存';

  @override
  String get exporting => '正在导出视频…';

  @override
  String get exportSuccess => '已保存到相册。';

  @override
  String get exportFailed => '导出失败。';

  @override
  String exportFailedWithMessage(String message) {
    return '导出失败：$message';
  }

  @override
  String get saveCancelled => '已取消保存。';

  @override
  String get hideTimeline => '隐藏时间轴';

  @override
  String get showTimeline => '显示时间轴';

  @override
  String get resumeEditing => '继续编辑';

  @override
  String resumeEditingSubtitle(int count, String updated) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个文字层 · 更新于 $updated',
      zero: '无文字层 · 更新于 $updated',
    );
    return '$_temp0';
  }

  @override
  String get projectNotFound => '找不到已保存的项目。';

  @override
  String get settingsTitle => '设置';

  @override
  String get exportQualitySection => '导出画质';

  @override
  String get exportQualityRecommendedTitle => '推荐';

  @override
  String get exportQualityRecommendedBody =>
      '上限 1080p，不放大。仅修剪时使用流复制（接近 CapCut 默认）。';

  @override
  String get exportQualityHighTitle => '更高画质';

  @override
  String get exportQualityHighBody => '最佳细节（CRF 18）。始终重新编码，耗时更长。';

  @override
  String get exportQualitySmallerTitle => '更小文件';

  @override
  String get exportQualitySmallerBody => '导出更快、文件更小。仅修剪时使用流复制。';

  @override
  String get exportQualityOriginalTitle => '匹配原片';

  @override
  String get exportQualityOriginalBody => '尽可能保留原始码流。仅在有文字或旋转时轻量编码。';

  @override
  String get addMusic => '添加音乐';

  @override
  String get importMusicFile => '导入音频文件';

  @override
  String get searchMusicHint => '搜索免版税音乐';

  @override
  String get musicCatalogAttribution => '可商用，无需署名（Pixabay / Mixkit）。';

  @override
  String get musicCatalogUnavailable => '无法加载曲库。请导入文件，或检查文字模板服务器地址。';

  @override
  String get musicLocalOnlyHint => '从设备导入 MP3、M4A 或 WAV 文件。';

  @override
  String get musicNoResults => '未找到曲目。';

  @override
  String musicImportFailed(String message) {
    return '无法添加音乐：$message';
  }

  @override
  String get useMusicTrack => '使用';

  @override
  String get musicPreviewFailed => '无法预览此曲目。';

  @override
  String get removeMusic => '移除音乐';

  @override
  String get retry => '重试';

  @override
  String get musicCatalogSection => '音乐曲库';

  @override
  String get musicCatalogReady => 'Pixabay Music';

  @override
  String get musicCatalogBody =>
      '可商用、无需署名。服务器设置 PIXABAY_API_KEY 时用 Pixabay Music，否则用 Mixkit。';

  @override
  String get splitVideo => '分割';

  @override
  String get deleteSegment => '删除片段';

  @override
  String get splitOutOfRange => '请将播放头移到片段内再分割。';

  @override
  String get splitTooShort => '每段至少需要 1 秒。';

  @override
  String get splitFailed => '无法分割片段。';

  @override
  String splitSuccess(String time) {
    return '已在 $time 分割';
  }

  @override
  String get cannotDeleteLastSegment => '至少必须保留一个片段。';

  @override
  String get undo => '撤销';

  @override
  String get redo => '重做';
}
