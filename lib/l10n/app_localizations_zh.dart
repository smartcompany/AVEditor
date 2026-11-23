// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'EasyClip';

  @override
  String get pickFromGallery => '从相册选择';

  @override
  String get addTimelineMedia => '添加视频或照片';

  @override
  String get galleryPickerTitle => '相册';

  @override
  String get galleryPickerHint => '点按媒体可预览，用圆圈选择。';

  @override
  String get galleryPickerEmpty => '没有照片或视频。';

  @override
  String gallerySelectedCount(int count) {
    return '已选 $count 项';
  }

  @override
  String get galleryAddSelected => '添加';

  @override
  String galleryAddSelectedCount(int count) {
    return '添加（$count）';
  }

  @override
  String get gallerySelect => '选择';

  @override
  String get galleryDeselect => '取消选择';

  @override
  String get gallerySelectToggle => '切换选择';

  @override
  String get galleryPhotoPreview => '照片';

  @override
  String get galleryVideoPreview => '视频';

  @override
  String get galleryBackToGrid => '返回';

  @override
  String get galleryManageAccess => '管理';

  @override
  String get galleryRetry => '重试';

  @override
  String get galleryTabGallery => '相册';

  @override
  String get galleryTabBackgrounds => '背景';

  @override
  String get galleryBackgroundsEmpty => '暂无背景模板。';

  @override
  String galleryBackgroundsLoadFailed(String error) {
    return '无法加载背景：$error';
  }

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
  String get addSticker => '添加贴纸';

  @override
  String get stickerSearchHint => '搜索 Giphy 贴纸';

  @override
  String get stickerPoweredByGiphy => 'Powered by GIPHY';

  @override
  String get stickerApiKeyMissing => '未配置 Giphy API 密钥。';

  @override
  String get stickerLoadFailed => '无法加载贴纸。';

  @override
  String get stickerDownloadFailed => '无法下载该贴纸。';

  @override
  String get stickerEmpty => '未找到贴纸。';

  @override
  String get addTemplateText => '添加模板文字';

  @override
  String get rotateVideo => '旋转视频';

  @override
  String get export => '导出';

  @override
  String get uploadShorts => '上传到 YouTube';

  @override
  String get saveToGallery => '保存到相册';

  @override
  String get saveToAlbum => '保存到相册';

  @override
  String get cancel => '取消';

  @override
  String get videoNotSelected => '未选择视频。';

  @override
  String videoPickError(String message) {
    return '无法打开视频：$message';
  }

  @override
  String get videoPickEmpty => '无法打开此视频。如果文件仍在 iCloud，请先在“照片”中下载后再试。';

  @override
  String get permissionPhotosDenied => '照片库访问已关闭，请在设置中开启。';

  @override
  String get permissionCameraDenied => '相机访问已关闭，请在设置中开启。';

  @override
  String get openSettings => '设置';

  @override
  String get comingSoon => '即将推出';

  @override
  String get youtubeUploadNeedsSignIn => '上传前需要登录 YouTube。登录尚未接通，因此没有开始上传。';

  @override
  String get trimStart => '修剪起点';

  @override
  String get trimEnd => '修剪终点';

  @override
  String get textOverlayHint => '点按输入文字';

  @override
  String get uploadTitleHint => '视频标题';

  @override
  String get uploadDescriptionHint => '描述（可选）';

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
  String get deleteTextConfirm => '删除此文字？';

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
  String get textStudioTabTemplates => '文字';

  @override
  String get textStudioTabTextTemplates => '文字模板';

  @override
  String get textStudioTabFonts => '字体';

  @override
  String get textStudioTabStyle => '样式';

  @override
  String get textStudioTabEffects => '编辑效果';

  @override
  String get textStudioTabAnimation => '动画';

  @override
  String get textStudioTabBubbles => '气泡';

  @override
  String get textStudioDefault => '默认';

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
  String get convertingVideo => '正在转换视频…';

  @override
  String get openingVideo => '正在打开视频…';

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
  String get draftBadge => '草稿';

  @override
  String get startNewClip => '再做一个';

  @override
  String get exportShareHint => '分享后，回来再做下一条。';

  @override
  String get pushDraftTitle => '继续完成你的片段';

  @override
  String get pushDraftBody24 => '你有未完成的编辑项目。打开 EasyClip 接着做吧。';

  @override
  String get pushDraftBody72 => '还没完成——打开后导出即可。';

  @override
  String get pushShareTitle => '准备发布了吗？';

  @override
  String get pushShareBody => '导出视频已保存。分享到 YouTube、Instagram 或 TikTok。';

  @override
  String get pushCatalogTitle => '新编辑素材';

  @override
  String get pushCatalogBody => '新的转场和文字样式已上线，下一条试试吧。';

  @override
  String get projectsSection => '项目';

  @override
  String get noProjectsYet => '还没有项目。请先在上方选择视频开始。';

  @override
  String projectListSubtitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个文字层',
      zero: '无文字层',
    );
    return '$_temp0';
  }

  @override
  String get deleteProject => '删除项目';

  @override
  String get deleteProjectConfirm => '要删除此项目吗？此操作无法撤销。';

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
  String get recordVoice => '录音';

  @override
  String get startVoiceRecording => '开始录音';

  @override
  String get stopVoiceRecording => '停止';

  @override
  String get voiceRecordingTitle => '录音';

  @override
  String get voiceRecordPermissionDenied => '录音需要麦克风权限。';

  @override
  String get voiceRecordTooShort => '录音太短。';

  @override
  String get voiceRecordFailed => '无法保存录音。';

  @override
  String get importMusicFile => '导入音频文件';

  @override
  String get searchMusicHint => '搜索免版税音乐';

  @override
  String get searchSfxHint => '搜索音效';

  @override
  String get musicTabMusic => '音乐';

  @override
  String get musicTabSfx => '音效';

  @override
  String get musicGenreAll => '全部';

  @override
  String get musicGenreTravel => '旅行';

  @override
  String get musicGenreBeauty => '美妆';

  @override
  String get musicGenreFashion => '时尚';

  @override
  String get musicGenreHappy => '欢快';

  @override
  String get musicGenreEnergetic => '动感';

  @override
  String get musicGenreChill => '轻松';

  @override
  String get musicGenreCinematic => '电影感';

  @override
  String get musicGenreRomantic => '浪漫';

  @override
  String get musicGenreSports => '运动';

  @override
  String get musicGenreNature => '自然';

  @override
  String get musicGenreCooking => '美食';

  @override
  String get musicGenreCorporate => '商务';

  @override
  String get musicGenreHipHop => '嘻哈';

  @override
  String get musicGenrePop => '流行';

  @override
  String get musicGenreKids => '儿童';

  @override
  String get sfxGenreWhoosh => '嗖嗖';

  @override
  String get sfxGenreTransition => '转场';

  @override
  String get sfxGenreImpact => '撞击';

  @override
  String get sfxGenreGlitch => '故障';

  @override
  String get sfxGenreNotification => '通知';

  @override
  String get sfxGenreGame => '游戏';

  @override
  String get sfxGenreTech => '科技';

  @override
  String get sfxGenreUi => '界面';

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
  String get musicCatalogBody => '可商用，无需署名（Pixabay / Mixkit）。';

  @override
  String get splitVideo => '分割';

  @override
  String get transition => '转场';

  @override
  String get transitionSheetTitle => '转场效果';

  @override
  String get transitionSheetSubtitle => '应用到离播放头最近的剪辑处。';

  @override
  String get transitionNone => '无';

  @override
  String get transitionCatalogUnavailable => '无法加载转场效果。';

  @override
  String get transitionApplied => '已应用转场。';

  @override
  String get transitionNeedsCuts => '请先分割片段再添加转场。';

  @override
  String get transitionDuration => '时长';

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

  @override
  String get uploadVisibility => '公开范围';

  @override
  String get uploadThumbnail => '缩略图';

  @override
  String get uploadThumbnailSelect => '选择缩略图';

  @override
  String get uploadThumbnailAuto => '自动';

  @override
  String get uploadThumbnailFromPhoto => '从照片选择';

  @override
  String get uploadPlaylist => '播放列表';

  @override
  String get uploadPlaylistNone => '不加入播放列表';

  @override
  String get uploadPlaylistLoad => '加载播放列表';

  @override
  String get uploadPlaylistEmpty => '此频道没有播放列表。';

  @override
  String get uploadPlaylistFailed => '无法加载播放列表。';

  @override
  String get uploadAudience => '观众';

  @override
  String get uploadAudienceNotForKids => '非儿童向';

  @override
  String get uploadAudienceForKids => '儿童向';

  @override
  String get uploadAudienceHelp => 'YouTube 要求声明。儿童向视频功能会受限。';

  @override
  String get uploadAgeRestriction => '年龄限制';

  @override
  String get uploadAgeRestrictionHelp => '仅 18 岁以上可观看。儿童向内容不能使用。';

  @override
  String get uploadMoreDetails => '更多';

  @override
  String get uploadFewerDetails => '收起';

  @override
  String get uploadShortsCaption => '添加视频说明';

  @override
  String get uploadLocation => '位置';

  @override
  String get uploadLocationHint => '地点名称';

  @override
  String get uploadLocationNotFound => '找不到该地点。';

  @override
  String get uploadRelatedVideo => '相关视频';

  @override
  String get uploadRelatedVideoHint => 'YouTube 链接或视频 ID';

  @override
  String get uploadRelatedVideoInvalid => '请检查相关视频地址。';

  @override
  String get uploadPaidPromotion => '付费推广和品牌';

  @override
  String get uploadPaidPromotionHelp => '视频含有付费产品植入时打开。上传时会发给 YouTube。';

  @override
  String get uploadAlteredContent => 'AI 或合成内容';

  @override
  String get uploadAlteredContentHelp => '画面是逼真的合成或改动影像时打开。';

  @override
  String get uploadTags => '标签';

  @override
  String get uploadTagsHint => '用逗号分隔';

  @override
  String get exportComplete => '导出完成';

  @override
  String get savedToDevice => '已保存到设备';

  @override
  String get shareContentTitle => '分享内容';

  @override
  String get share => '分享';

  @override
  String shareAppMessage(String url) {
    return '用 EasyClip 快速剪辑短视频。\n$url';
  }

  @override
  String get exportDone => '完成';

  @override
  String get shareToYouTube => 'YouTube';

  @override
  String get shareMore => '更多';

  @override
  String get shareAppMissing => '未安装该应用。';

  @override
  String get shareFacebookOpened => '请在列表中选择 Facebook 以完成发布。';

  @override
  String get shareFacebookPosted => '已发布到 Facebook';

  @override
  String get shareFacebookCancelled => '已取消 Facebook 发布。';

  @override
  String shareFacebookFailed(String message) {
    return '无法发布到 Facebook。$message';
  }

  @override
  String uploadPartialFailure(String videoId, String message) {
    return '视频已上传 ($videoId)。后续步骤失败: $message';
  }

  @override
  String get canvasRatio => '比例';

  @override
  String get canvasRatioOriginal => '原始';

  @override
  String get textColorCustom => '自定义';

  @override
  String get textColorDone => '完成';

  @override
  String get overlayFontBasic => '基础';

  @override
  String get overlayFontNotoSans => 'Noto Sans';

  @override
  String get overlayFontGaegu => 'Gaegu';

  @override
  String get overlayFontBlackHan => 'Black Han';

  @override
  String get overlayFontDoHyeon => 'Do Hyeon';

  @override
  String get overlayFontGothicA1 => 'Gothic A1';

  @override
  String get overlayFontRoboto => 'Roboto';

  @override
  String get overlayFontJua => 'Jua';

  @override
  String get overlayFontBagelFat => 'Bagel Fat';

  @override
  String get overlayFontSongMyung => 'Song Myung';

  @override
  String get overlayFontHiMelody => 'Hi Melody';

  @override
  String get overlayFontStylish => 'Stylish';

  @override
  String get overlayFontNanumPen => 'Nanum Pen';

  @override
  String get overlayFontGasoek => 'Gasoek';

  @override
  String get overlayFontCycleHint => '更换字体';

  @override
  String get textFont => 'Font';

  @override
  String projectDefaultName(int n) {
    return '项目 $n';
  }

  @override
  String get projectNameTitle => '项目名称';

  @override
  String get projectNameHint => '输入项目名称';

  @override
  String proTitle(String appName) {
    return '$appName Pro';
  }

  @override
  String get proSubtitle => '解锁全部特效，让你的短视频更出彩。';

  @override
  String get proBenefitEffects => '全部 Pro 转场与文字特效';

  @override
  String get proBenefitNoAds => '无广告导出';

  @override
  String get proBenefitFuture => '后续新增的 Pro 功能';

  @override
  String get proSubscribe => '开始 Pro';

  @override
  String get proRestore => '恢复购买';

  @override
  String get proAnnualBadge => '最划算';

  @override
  String get proLegal => '订阅将自动续订，可随时在商店账户设置中取消。';

  @override
  String get proStoreUnavailable => '尚未连接应用商店。';

  @override
  String get proDebugToggle => '测试 Pro（仅调试）';

  @override
  String get proActive => 'Pro 已开通';

  @override
  String planActive(String plan) {
    return '$plan 已开通';
  }

  @override
  String planActiveWithPeriod(String plan, String period) {
    return '$plan · $period 已开通';
  }

  @override
  String get planCurrentSubscription => '当前方案';

  @override
  String get planSwitchToAnnual => '切换到年付';

  @override
  String get planSwitchToMonthly => '切换到月付';

  @override
  String planUpgradeCta(String plan) {
    return '升级到 $plan';
  }

  @override
  String planDowngradeCta(String plan) {
    return '改为 $plan';
  }

  @override
  String planDowngradeHint(String current) {
    return '将在当前周期结束后生效。在此之前仍保留 $current。';
  }

  @override
  String get planPeriodDowngradeBlocked => '要从年付改为月付，请在商店中管理订阅。';

  @override
  String get planManageSubscription => '管理订阅';

  @override
  String get planUpgradeBadge => '升级';

  @override
  String get planDowngradeBadge => '续订时生效';

  @override
  String planUpgradeSheetTitle(String plan) {
    return '升级到 $plan';
  }

  @override
  String get planUpgradeToday => '当前';

  @override
  String get planUpgradeAfter => '升级后';

  @override
  String get planUpgradeContinue => '继续';

  @override
  String get planUpgradeLegal => '继续将立即升级方案，并在今天扣款。当前方案剩余时长由商店折抵。下次续订起按新价格计费。';

  @override
  String planUpgradePriceDetail(String plan, String price, String period) {
    return '$plan，$price · $period';
  }

  @override
  String get proInactive => '免费版';

  @override
  String get proPurchaseFailed => '购买未完成，请重试。';

  @override
  String get proRestoreNone => '没有可恢复的购买。';

  @override
  String get proSection => '订阅';

  @override
  String get premiumExportTitle => '此视频包含付费特效';

  @override
  String get premiumExportBody => '可为每个特效观看广告解锁，或订阅一次性解锁全部。';

  @override
  String get premiumExportWithPro => '订阅解锁全部';

  @override
  String get premiumExportWatchAd => '看广告后使用';

  @override
  String premiumExportWatchAdsCount(int count, int credits) {
    return '观看 $count 次广告（$credits 积分）';
  }

  @override
  String premiumExportSpendCredits(int credits, int balance) {
    return '使用 $credits 积分（余额 $balance）';
  }

  @override
  String premiumExportCreditCost(int credits, int balance) {
    return '本次导出需要 $credits 积分。余额：$balance。';
  }

  @override
  String get premiumExportStrip => '去除锁定特效后保存';

  @override
  String get premiumExportEffectUnlocked => '已解锁';

  @override
  String get premiumExportContinue => '继续保存';

  @override
  String get premiumAdNotFinished => '完整观看广告后即可解锁此特效。';

  @override
  String get premiumCreditsSpendFailed => '积分不足。请继续观看广告或订阅。';

  @override
  String get loginRequiredForSubscribe => '订阅前请先登录。';

  @override
  String get accountSection => '账户';

  @override
  String get accountSignIn => '登录';

  @override
  String get accountSignOut => '退出登录';

  @override
  String accountSignedInAs(String name) {
    return '已登录为 $name';
  }

  @override
  String creditsBalanceLabel(int balance) {
    return '积分 $balance';
  }

  @override
  String get planPlusLabel => 'Plus';

  @override
  String get planProLabel => 'Pro';

  @override
  String get planStudioLabel => 'Studio';

  @override
  String get planBillingMonthly => '月付';

  @override
  String get planBillingAnnual => '年付';

  @override
  String get planAnnualSaveBadge => '选年付，相当于送 2 个月';

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
    return '每月 $credits 积分，用于高级效果。';
  }

  @override
  String planProSubtitle(int credits) {
    return '每月 $credits 积分，并解锁 AI 工具。';
  }

  @override
  String planStudioSubtitle(int credits) {
    return '重度创作者每月 $credits 积分。';
  }

  @override
  String planPlusBenefit1(int credits) {
    return '每月发放 $credits 积分';
  }

  @override
  String get planPlusBenefit2 => '全部高级转场与文字效果';

  @override
  String get planPlusBenefit3 => '导出消耗积分 · 不足时可看广告补充';

  @override
  String planProBenefit1(int credits) {
    return '每月发放 $credits 积分';
  }

  @override
  String get planProBenefit2 => '全部高级转场与文字效果';

  @override
  String get planProBenefit3 => '解锁 AI 工具';

  @override
  String get planProBenefit4 => '导出消耗积分 · 不足时可看广告补充';

  @override
  String planStudioBenefit1(int credits) {
    return '每月发放 $credits 积分';
  }

  @override
  String get planStudioBenefit2 => '全部高级转场与文字效果';

  @override
  String get planStudioBenefit3 => '解锁 AI 工具';

  @override
  String get planStudioBenefit4 => 'Studio 创作扩展与新工具优先体验';

  @override
  String get planStudioBenefit5 => '导出消耗积分 · 不足时可看广告补充';

  @override
  String planSubscribeCta(String plan) {
    return '订阅 $plan';
  }

  @override
  String get planChooseTitle => '选择方案';

  @override
  String get planCompareTitle => '方案对比';

  @override
  String get planComparePlusEffects => 'Plus 效果';

  @override
  String get planCompareProEffects => 'Pro 效果';

  @override
  String get planCompareAi => 'AI 工具';

  @override
  String get planCompareCredits => '每月 AI 积分';

  @override
  String get planCompareStudioExtras => 'Studio 附加功能';

  @override
  String get proBenefitAi => 'Pro 与 Studio 可使用 AI 工具';

  @override
  String get uploadAccountTitle => '上传到的 YouTube 账号';

  @override
  String get uploadAccountNone => '尚未连接账号';

  @override
  String get uploadAccountConnect => '连接';

  @override
  String get uploadAccountSwitch => '切换';

  @override
  String get uploadErrorTitle => '无法上传';

  @override
  String get uploadErrSuspended =>
      '此 Google 账号的 YouTube 频道已被停用，无法上传视频。请使用其他账号登录。';

  @override
  String get uploadErrNoChannel =>
      '此 Google 账号还没有 YouTube 频道。请在 YouTube 应用中创建频道后重试，或使用其他账号登录。';

  @override
  String get uploadErrUploadLimit => '此频道已达到今日上传上限，请在 24 小时后重试。';

  @override
  String get uploadErrQuota => 'YouTube 当前繁忙，暂时无法上传。请稍后重试。';

  @override
  String get uploadErrAuth => '登录已过期，请重新登录。';

  @override
  String get uploadErrPermission => '需要允许 YouTube 上传权限才能上传视频。';

  @override
  String get uploadErrNetwork => '网络连接不稳定，请检查网络后重试。';

  @override
  String get uploadErrUnknown => '请稍后重试。如果问题持续，请告诉我们下面的代码。';

  @override
  String uploadErrCode(String code) {
    return '错误代码：$code';
  }

  @override
  String get uploadSwitchAccountAction => '使用其他账号登录';

  @override
  String uploadPartialDone(String steps) {
    return '视频已上传，但以下设置未能应用：$steps。你可以在 YouTube 工作室中修改。';
  }

  @override
  String get uploadStepThumbnail => '缩略图';

  @override
  String get uploadStepPlaylist => '播放列表';

  @override
  String get uploadStepAgeRestriction => '年龄限制';

  @override
  String get uploadStepLocation => '位置';

  @override
  String get uploadOk => '确定';

  @override
  String get uploadDoneTitle => '已上传到 YouTube';

  @override
  String get uploadDoneProcessing => 'YouTube 处理可能需要几分钟，可能无法立即播放。';

  @override
  String uploadDoneVisibility(String visibility) {
    return '公开范围：$visibility';
  }

  @override
  String get uploadDoneOpen => '在 YouTube 上观看';

  @override
  String get uploadDoneCopy => '复制链接';

  @override
  String get uploadDoneCopied => '链接已复制';

  @override
  String get uploadDoneShare => '分享';

  @override
  String get uploadDoneClose => '完成';

  @override
  String shareAppPosted(String app) {
    return '已分享到 $app';
  }

  @override
  String shareAppCancelled(String app) {
    return '已取消 $app 发布。';
  }

  @override
  String shareAppFailed(String app, String message) {
    return '无法分享到 $app。$message';
  }

  @override
  String get tiktokUploadTitle => '发布到 TikTok';

  @override
  String get tiktokAccountTitle => '发布到的 TikTok 账号';

  @override
  String get tiktokCaptionHint => '说明、#话题、@提及';

  @override
  String get tiktokPrivacyChoose => '请选择谁可以观看';

  @override
  String get tiktokPrivacyPublic => '所有人';

  @override
  String get tiktokPrivacyFriends => '朋友（互相关注）';

  @override
  String get tiktokPrivacyFollowers => '粉丝';

  @override
  String get tiktokPrivacySelf => '仅自己';

  @override
  String get tiktokInteractionTitle => '允许他人';

  @override
  String get tiktokAllowComment => '评论';

  @override
  String get tiktokAllowDuet => '合拍';

  @override
  String get tiktokAllowStitch => '拼接';

  @override
  String get tiktokInteractionOff => '已在 TikTok 设置中关闭';

  @override
  String get tiktokDisclose => '披露视频内容';

  @override
  String get tiktokDiscloseHelp => '如果视频推广商品、品牌或服务，请开启。';

  @override
  String get tiktokYourBrand => '你的品牌';

  @override
  String get tiktokYourBrandHelp => '推广你自己或你的业务。将标注为“推广内容”。';

  @override
  String get tiktokBrandedContent => '品牌内容';

  @override
  String get tiktokBrandedContentHelp => '推广其他品牌或第三方。将标注为“付费合作”。';

  @override
  String get tiktokDiscloseNeedOne => '请至少选择一项才能发布。';

  @override
  String get tiktokBrandedNotPrivate => '品牌内容不能设为“仅自己”。';

  @override
  String tiktokConsent(String policies) {
    return '发布即表示你同意 TikTok 的$policies。';
  }

  @override
  String get tiktokMusicPolicy => '音乐使用确认';

  @override
  String get tiktokBrandPolicy => '品牌内容政策';

  @override
  String get tiktokAnd => '和';

  @override
  String get tiktokPost => '发布';

  @override
  String tiktokUploading(int percent) {
    return '正在上传 $percent%';
  }

  @override
  String get tiktokProcessing => 'TikTok 正在处理…';

  @override
  String get tiktokDoneTitle => '已发布到 TikTok';

  @override
  String get tiktokDoneProcessing => '可能需要几分钟才会显示在你的主页上。';

  @override
  String get tiktokOpen => '在 TikTok 中查看';

  @override
  String get tiktokFinishInApp => '改在 TikTok 应用中完成';

  @override
  String tiktokTooLong(int max) {
    return '此账号最多可发布 $max 秒的视频。';
  }

  @override
  String get tiktokConnectHelp => '连接 TikTok 账号后即可直接在此发布。';

  @override
  String get tiktokErrServer => 'TikTok 连接尚未设置完成，请稍后重试。';

  @override
  String get tiktokErrDenied => '需要允许发布到 TikTok 才能继续。';

  @override
  String get tiktokErrAuth => 'TikTok 登录已过期，请重新连接。';

  @override
  String get tiktokErrPrivateOnly =>
      '在 EasyClip 通过 TikTok 审核之前，只能从私密账号发布。请在 TikTok 应用的“设置和隐私”→“隐私”中开启“私密账号”，然后重试。';

  @override
  String get tiktokErrSpam => 'TikTok 暂时限制了发布，请稍后重试。';

  @override
  String get tiktokErrBanned => '此 TikTok 账号目前无法发布，请换一个账号。';

  @override
  String get tiktokErrPrivacyMismatch => '此账号不能使用该公开范围，请选择其他范围。';

  @override
  String get tiktokErrFailed => 'TikTok 无法处理该视频。';

  @override
  String get tiktokSwitchAccount => '使用其他账号';
}
