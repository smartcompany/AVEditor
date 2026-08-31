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
}
