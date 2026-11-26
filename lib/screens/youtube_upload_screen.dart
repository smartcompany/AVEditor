import 'dart:io';

import 'package:aveditor/services/analytics_service.dart';
import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/screens/thumbnail_editor_screen.dart';
import 'package:aveditor/screens/tiktok_cover_picker_screen.dart';
import 'package:aveditor/services/app_settings_service.dart';
import 'package:aveditor/services/export_service.dart';
import 'package:aveditor/services/export_share_service.dart';
import 'package:aveditor/services/tiktok_auth_service.dart';
import 'package:aveditor/services/tiktok_post_service.dart';
import 'package:aveditor/services/youtube_auth_service.dart';
import 'package:aveditor/services/youtube_errors.dart';
import 'package:aveditor/services/youtube_upload_service.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/utils/cross_post_privacy.dart';
import 'package:aveditor/utils/logged_snackbar.dart';
import 'package:aveditor/widgets/upload_form_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

class YouTubeUploadScreen extends StatefulWidget {
  const YouTubeUploadScreen({
    super.key,
    required this.project,
    this.preparedExportPath,
  });

  final VideoProject project;

  /// Exported file from the share screen. Skips a second encode when set.
  final String? preparedExportPath;

  @override
  State<YouTubeUploadScreen> createState() => _YouTubeUploadScreenState();
}

class _YouTubeUploadScreenState extends State<YouTubeUploadScreen> {
  final _descriptionController = TextEditingController();
  final _relatedController = TextEditingController();
  final _tagsController = TextEditingController();
  String _privacy = 'public';
  bool _madeForKids = false;
  bool _paidPromotion = false;
  bool _syntheticMedia = false;
  bool _busy = false;
  _UploadBusyPhase _busyPhase = _UploadBusyPhase.idle;
  double _busyProgress = 0;
  bool _moreOpen = false;
  String? _thumbnailPath;
  GoogleSignInAccount? _account;
  bool _accountLoading = true;

  /// Set once the video is on YouTube; the screen then shows the result.
  String? _uploadedId;

  /// Settings that could not be applied after the upload, if any.
  String? _partialSteps;

  /// Shown on the done screen when dual-posting to TikTok.
  String? _crossPostNote;

  /// Open URL for a successful TikTok cross-post (done screen).
  String? _tikTokCrossOpenUrl;

  VideoPlayerController? _preview;
  var _previewFailed = false;

  final _export = ExportService();
  final _upload = YouTubeUploadService();
  final _auth = YouTubeAuthService();
  final _settings = const AppSettingsService();

  // --- Optional TikTok cross-post ---
  var _alsoTikTok = false;
  final _tikTokAuth = TikTokAuthService();
  final _tikTokPosts = TikTokPostService();
  TikTokSession? _tikTokSession;
  TikTokCreatorInfo? _tikTokCreator;
  var _tikTokAccountLoading = false;
  String? _tikTokPrivacy;
  var _tikTokAllowComment = false;
  var _tikTokAllowDuet = false;
  var _tikTokAllowStitch = false;
  var _tikTokDisclose = false;
  var _tikTokYourBrand = false;
  var _tikTokBranded = false;
  var _tikTokCoverMs = 0;

  static const _tikTokSelfOnly = 'SELF_ONLY';

  @override
  void initState() {
    super.initState();
    _openPreview();
    _restoreAccount();
  }

  bool get _tikTokDisclosureIncomplete =>
      _tikTokDisclose && !_tikTokYourBrand && !_tikTokBranded;

  bool get _tikTokReady =>
      _tikTokCreator != null &&
      _tikTokPrivacy != null &&
      !_tikTokDisclosureIncomplete &&
      !(_tikTokDisclose &&
          _tikTokBranded &&
          _tikTokPrivacy == _tikTokSelfOnly);

  String? get _exportVideoPath {
    final prepared = widget.preparedExportPath?.trim();
    if (prepared != null && prepared.isNotEmpty) return prepared;
    return widget.project.primaryVideoPath;
  }

  Future<void> _restoreAccount() async {
    final account = await _auth.currentAccount();
    if (!mounted) return;
    setState(() {
      _account = account;
      _accountLoading = false;
    });
  }

  /// Connects an account, or replaces the current one.
  Future<bool> _changeAccount() async {
    setState(() => _accountLoading = true);
    try {
      final account = _account == null
          ? await _connectAccount()
          : await _auth.switchAccount();
      if (!mounted) return false;
      setState(() => _account = account);
      AnalyticsService.instance.log('youtube_account_switched');
      return true;
    } catch (error, stack) {
      debugPrint('[YouTubeUpload] 계정 변경 실패: $error\n$stack');
      if (!mounted) return false;
      // Switching signs the old account out first, so refresh what is shown.
      final current = await _auth.currentAccount();
      if (!mounted) return false;
      setState(() => _account = current);
      await _showError(error, offerSwitch: false);
      return false;
    } finally {
      if (mounted) setState(() => _accountLoading = false);
    }
  }

  Future<GoogleSignInAccount?> _connectAccount() async {
    await _auth.signIn();
    return _auth.currentAccount();
  }

  Future<void> _setAlsoTikTok(bool value) async {
    setState(() => _alsoTikTok = value);
    if (!value) return;
    setState(() => _tikTokAccountLoading = true);
    try {
      final session = await _tikTokAuth.currentSession();
      if (session == null) {
        if (!mounted) return;
        setState(() {
          _tikTokSession = null;
          _tikTokCreator = null;
          _tikTokAccountLoading = false;
        });
        return;
      }
      final creator = await _tikTokPosts.creatorInfo(session.accessToken);
      if (!mounted) return;
      setState(() {
        _tikTokSession = session;
        _tikTokCreator = creator;
        // Prefer Only me first — unaudited TikTok apps reject public posts.
        _tikTokPrivacy ??= creator.privacyOptions.contains(_tikTokSelfOnly)
            ? _tikTokSelfOnly
            : CrossPostPrivacy.youtubeToTikTok(
                _privacy,
                creator.privacyOptions,
              );
        _tikTokAccountLoading = false;
      });
    } catch (error) {
      debugPrint('[YouTubeUpload] TikTok session load failed: $error');
      if (!mounted) return;
      setState(() {
        _tikTokSession = null;
        _tikTokCreator = null;
        _tikTokAccountLoading = false;
      });
    }
  }

  Future<void> _connectTikTok({bool fresh = false}) async {
    setState(() => _tikTokAccountLoading = true);
    try {
      if (fresh) await _tikTokAuth.signOut();
      final session = await _tikTokAuth.signIn(freshAccount: fresh);
      final creator = await _tikTokPosts.creatorInfo(session.accessToken);
      if (!mounted) return;
      setState(() {
        _tikTokSession = session;
        _tikTokCreator = creator;
        _tikTokPrivacy ??= creator.privacyOptions.contains(_tikTokSelfOnly)
            ? _tikTokSelfOnly
            : CrossPostPrivacy.youtubeToTikTok(
                _privacy,
                creator.privacyOptions,
              );
      });
    } catch (error) {
      debugPrint('[YouTubeUpload] TikTok connect failed: $error');
      if (!mounted) return;
      showLoggedSnackBar(context, error.toString(), error: error);
    } finally {
      if (mounted) setState(() => _tikTokAccountLoading = false);
    }
  }

  Future<void> _pickTikTokCover() async {
    final path = _exportVideoPath;
    if (path == null || path.isEmpty) return;
    final nav = Navigator.of(context);
    await _preview?.pause();
    if (!mounted) return;
    final picked = await nav.push<int>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => TikTokCoverPickerScreen(
          videoPath: path,
          initialMs: _tikTokCoverMs,
        ),
      ),
    );
    if (!mounted || picked == null) return;
    setState(() => _tikTokCoverMs = picked);
  }

  void _setBusyProgress(_UploadBusyPhase phase, [double progress = 0]) {
    final next = progress.clamp(0.0, 1.0);
    final nextPercent = (next * 100).round();
    final samePhase = _busyPhase == phase;
    final samePercent = (_busyProgress * 100).round() == nextPercent;
    if (samePhase && samePercent) return;
    if (!mounted) return;
    setState(() {
      _busyPhase = phase;
      _busyProgress = next;
    });
  }

  String _busyStatusText(AppLocalizations l10n) {
    final percent = (_busyProgress * 100).round();
    return switch (_busyPhase) {
      _UploadBusyPhase.exporting => l10n.youtubeExporting(percent),
      _UploadBusyPhase.uploadingYouTube => _alsoTikTok
          ? l10n.crossPostUploadingYouTube(percent)
          : l10n.youtubeUploading(percent),
      _UploadBusyPhase.finishingYouTube => l10n.youtubeFinishing,
      _UploadBusyPhase.uploadingTikTok =>
        l10n.crossPostUploadingTikTok(percent),
      _UploadBusyPhase.processingTikTok => l10n.crossPostProcessingTikTok,
      _UploadBusyPhase.idle => l10n.youtubeUploading(0),
    };
  }

  /// Button fill: one platform = full bar; dual-post splits 50/50.
  double get _overallBusyProgress {
    final p = _busyProgress.clamp(0.0, 1.0);
    if (_alsoTikTok) {
      return switch (_busyPhase) {
        _UploadBusyPhase.idle => 0,
        _UploadBusyPhase.exporting => p * 0.08,
        _UploadBusyPhase.uploadingYouTube => 0.08 + p * 0.40,
        _UploadBusyPhase.finishingYouTube => 0.50,
        _UploadBusyPhase.uploadingTikTok => 0.50 + p * 0.42,
        _UploadBusyPhase.processingTikTok => 0.94,
      };
    }
    return switch (_busyPhase) {
      _UploadBusyPhase.idle => 0,
      _UploadBusyPhase.exporting => p * 0.15,
      _UploadBusyPhase.uploadingYouTube => 0.15 + p * 0.75,
      _UploadBusyPhase.finishingYouTube => 0.96,
      _UploadBusyPhase.uploadingTikTok ||
      _UploadBusyPhase.processingTikTok => 1,
    };
  }

  String _tikTokOpenUrl(TikTokPublishStatus status) {
    final username = _tikTokCreator?.username ?? '';
    final postId = status.postIds?.firstOrNull;
    if (username.isEmpty) return 'https://www.tiktok.com/';
    if (postId == null) return 'https://www.tiktok.com/@$username';
    return 'https://www.tiktok.com/@$username/video/$postId';
  }

  /// Returns true when the post had to fall back to Only me (unaudited app).
  Future<bool> _postToTikTok(String videoPath) async {
    final session = _tikTokSession;
    final privacy = _tikTokPrivacy;
    final creator = _tikTokCreator;
    if (session == null || privacy == null || creator == null) {
      throw StateError('tiktok_not_ready');
    }
    final maxCover =
        ((_preview?.value.duration.inMilliseconds ?? 1) - 1).clamp(0, 1 << 30);

    Future<TikTokPublishStatus> publish(String privacyLevel) async {
      final info = TikTokPostInfo(
        title: _titleFromCaption(_descriptionController.text.trim()),
        privacyLevel: privacyLevel,
        allowComment: _tikTokAllowComment,
        allowDuet: _tikTokAllowDuet,
        allowStitch: _tikTokAllowStitch,
        coverTimestampMs: _tikTokCoverMs.clamp(0, maxCover),
        brandOrganic: _tikTokDisclose && _tikTokYourBrand,
        brandedContent: _tikTokDisclose && _tikTokBranded,
      );
      _setBusyProgress(_UploadBusyPhase.uploadingTikTok, 0);
      final publishId = await _tikTokPosts.publish(
        accessToken: session.accessToken,
        file: File(videoPath),
        info: info,
        onProgress: (value) =>
            _setBusyProgress(_UploadBusyPhase.uploadingTikTok, value),
      );
      _setBusyProgress(_UploadBusyPhase.processingTikTok);
      final status = await _tikTokPosts.waitForPublish(
        session.accessToken,
        publishId,
      );
      if (status.state == TikTokPublishState.failed) {
        throw TikTokApiException(
          'publish_failed',
          message: status.failReason,
        );
      }
      return status;
    }

    try {
      final status = await publish(privacy);
      _tikTokCrossOpenUrl = _tikTokOpenUrl(status);
      return false;
    } on TikTokApiException catch (error) {
      // Unaudited TikTok apps may only Direct Post as SELF_ONLY.
      if (error.code == 'unaudited_client_can_only_post_to_private_accounts' &&
          privacy != _tikTokSelfOnly &&
          (creator.privacyOptions.contains(_tikTokSelfOnly) ||
              creator.privacyOptions.isEmpty)) {
        debugPrint(
          '[YouTubeUpload] TikTok unaudited — retry as SELF_ONLY',
        );
        final status = await publish(_tikTokSelfOnly);
        _tikTokCrossOpenUrl = _tikTokOpenUrl(status);
        if (mounted) {
          setState(() => _tikTokPrivacy = _tikTokSelfOnly);
        }
        return true;
      }
      rethrow;
    }
  }

  String _errorMessage(AppLocalizations l10n, YouTubeErrorKind kind) {
    return switch (kind) {
      YouTubeErrorKind.accountSuspended => l10n.uploadErrSuspended,
      YouTubeErrorKind.noChannel => l10n.uploadErrNoChannel,
      YouTubeErrorKind.uploadLimit => l10n.uploadErrUploadLimit,
      YouTubeErrorKind.quota => l10n.uploadErrQuota,
      YouTubeErrorKind.authExpired => l10n.uploadErrAuth,
      YouTubeErrorKind.permissionDenied => l10n.uploadErrPermission,
      YouTubeErrorKind.network => l10n.uploadErrNetwork,
      YouTubeErrorKind.cancelled ||
      YouTubeErrorKind.unknown => l10n.uploadErrUnknown,
    };
  }

  /// Short support code, never the raw response body.
  String? _errorCode(Object error, YouTubeErrorKind kind) {
    if (kind != YouTubeErrorKind.unknown) return null;
    if (error is YouTubeApiException) return '${error.step} ${error.code}';
    return error.runtimeType.toString();
  }

  /// Explains a failure in plain words. For account problems it offers to
  /// sign in with another account; returns true if the user switched.
  Future<bool> _showError(Object error, {bool offerSwitch = true}) async {
    final kind = classifyYouTubeError(error);
    if (kind == YouTubeErrorKind.cancelled) return false;
    final l10n = context.l10n;
    final code = _errorCode(error, kind);
    final canSwitch = offerSwitch && kind.suggestsSwitchAccount;
    final switchNow = await showDialog<bool>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          title: Text(l10n.uploadErrorTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_errorMessage(l10n, kind)),
              if (code != null) ...[
                const SizedBox(height: 12),
                SelectableText(
                  l10n.uploadErrCode(code),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(canSwitch ? l10n.cancel : l10n.uploadOk),
            ),
            if (canSwitch)
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.uploadSwitchAccountAction),
              ),
          ],
        );
      },
    );
    if (switchNow != true || !mounted) return false;
    return _changeAccount();
  }

  @override
  void dispose() {
    _preview?.dispose();
    _descriptionController.dispose();
    _relatedController.dispose();
    _tagsController.dispose();
    super.dispose();
  }

  List<ClipSegment> get _segments => widget.project.segments;

  Future<void> _openPreview() async {
    final controller = VideoPlayerController.file(
      File(widget.project.sourcePath),
    );
    _preview = controller;
    try {
      await controller.initialize();
      await controller.setLooping(false);
      final start = _segments.isEmpty ? Duration.zero : _segments.first.start;
      await controller.seekTo(start);
      if (!mounted) return;
      setState(() {});
    } catch (error, stack) {
      debugPrint('[YouTubeUpload] 미리보기 실패: $error\n$stack');
      if (!mounted) return;
      setState(() => _previewFailed = true);
    }
  }

  String _thumbnailDurationLabel() {
    final trimmed = widget.project.trimmedDuration;
    final duration = trimmed > Duration.zero
        ? trimmed
        : (_preview?.value.duration ?? Duration.zero);
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${duration.inMinutes}:$seconds';
  }

  String _titleFromCaption(String caption) {
    final line = caption
        .split('\n')
        .map((part) => part.trim())
        .firstWhere((part) => part.isNotEmpty, orElse: () => '');
    if (line.length <= 100) return line;
    return line.substring(0, 100);
  }

  Future<void> _editThumbnail() async {
    final path = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ThumbnailEditorScreen(project: widget.project),
      ),
    );
    if (!mounted || path == null) return;
    setState(() => _thumbnailPath = path);
  }

  Future<void> _submit() async {
    final l10n = context.l10n;
    var description = _descriptionController.text.trim();
    final title = _titleFromCaption(description);
    if (title.isEmpty) {
      showLoggedSnackBar(context, l10n.uploadTitleHint);
      return;
    }
    if (_alsoTikTok && !_tikTokReady) {
      showLoggedSnackBar(context, l10n.tiktokConnectHelp);
      return;
    }
    final relatedRaw = _relatedController.text.trim();
    final relatedId = youtubeVideoId(relatedRaw);
    if (relatedRaw.isNotEmpty && relatedId == null) {
      showLoggedSnackBar(context, l10n.uploadRelatedVideoInvalid);
      return;
    }
    final tags = youtubeTags(_tagsController.text);
    if (relatedId != null) {
      final link = 'https://www.youtube.com/watch?v=$relatedId';
      if (!description.contains(link)) {
        description = description.isEmpty ? link : '$description\n$link';
      }
    }

    setState(() {
      _busy = true;
      _busyPhase = _UploadBusyPhase.uploadingYouTube;
      _busyProgress = 0;
    });
    await _preview?.pause();
    debugPrint(
      '[YouTubeUpload] 시작 title="$title" '
      'privacy=$_privacy kids=$_madeForKids '
      'paid=$_paidPromotion synthetic=$_syntheticMedia '
      'tags=${tags.length} related=${relatedId ?? "none"} '
      'thumbnail=${_thumbnailPath == null ? "auto" : "custom"} '
      'alsoTikTok=$_alsoTikTok',
    );
    String? videoId;
    try {
      final signedIn = await _auth.isSignedIn;
      debugPrint(
        signedIn ? '[YouTubeUpload] 이미 로그인됨' : '[YouTubeUpload] 로그인 필요',
      );
      if (!signedIn) {
        await _auth.signIn();
        debugPrint('[YouTubeUpload] 로그인 완료');
        final account = await _auth.currentAccount();
        if (mounted) setState(() => _account = account);
      }
      debugPrint('[YouTubeUpload] 액세스 토큰 요청');
      final token = await _auth.accessToken();
      debugPrint('[YouTubeUpload] 액세스 토큰 준비됨');
      final prepared = widget.preparedExportPath;
      final String path;
      if (prepared != null && await File(prepared).exists()) {
        path = prepared;
        debugPrint('[YouTubeUpload] 이미 보낸 파일 사용 path=$path');
      } else {
        final quality = await _settings.getExportQualityProfile();
        debugPrint('[YouTubeUpload] 내보내기 시작 quality=${quality.name}');
        _setBusyProgress(_UploadBusyPhase.exporting, 0);
        var lastExportBucket = -1;
        path = await _export.exportForPreset(
          widget.project,
          quality: quality,
          onProgress: (progress) {
            _setBusyProgress(_UploadBusyPhase.exporting, progress);
            final percent = (progress.clamp(0.0, 1.0) * 100).round();
            final bucket = percent ~/ 10;
            if (bucket == lastExportBucket) return;
            lastExportBucket = bucket;
            debugPrint('[YouTubeUpload] 내보내기 $percent%');
          },
        );
        debugPrint('[YouTubeUpload] 내보내기 완료 path=$path');
      }
      _setBusyProgress(_UploadBusyPhase.uploadingYouTube, 0);
      videoId = await _upload.uploadProject(
        project: widget.project,
        exportedPath: path,
        accessToken: token,
        title: title,
        description: description,
        privacyStatus: _privacy,
        madeForKids: _madeForKids,
        tags: tags,
        containsSyntheticMedia: _syntheticMedia,
        paidPromotion: _paidPromotion,
        onProgress: (progress) =>
            _setBusyProgress(_UploadBusyPhase.uploadingYouTube, progress),
      );
      debugPrint('[YouTubeUpload] 업로드 완료 videoId=$videoId');
      AnalyticsService.instance.log('youtube_upload_completed');
      _setBusyProgress(_UploadBusyPhase.finishingYouTube);
      final followUp = await _applyDetails(token: token, videoId: videoId);

      String? crossNote;
      String? tikTokOpenUrl;
      if (_alsoTikTok) {
        try {
          final privateFallback = await _postToTikTok(path);
          AnalyticsService.instance.log('tiktok_post_completed', {
            'from': 'youtube_cross',
            'private_fallback': privateFallback,
          });
          crossNote = privateFallback
              ? l10n.crossPostTikTokOkPrivate
              : l10n.crossPostTikTokOk;
          tikTokOpenUrl = _tikTokCrossOpenUrl;
        } catch (error) {
          debugPrint('[YouTubeUpload] TikTok cross-post failed: $error');
          _tikTokCrossOpenUrl = null;
          final message = error is TikTokApiException &&
                  error.code ==
                      'unaudited_client_can_only_post_to_private_accounts'
              ? l10n.tiktokErrPrivateOnly
              : '$error';
          crossNote = l10n.crossPostTikTokFailed(message);
        }
      }

      if (!mounted) return;
      await _preview?.pause();
      setState(() {
        _uploadedId = videoId;
        _partialSteps = followUp;
        _crossPostNote = crossNote;
        _tikTokCrossOpenUrl = tikTokOpenUrl;
      });
    } catch (e, stack) {
      debugPrint('[YouTubeUpload] 실패: $e\n$stack');
      if (!mounted) return;
      if (videoId != null) {
        // The video is on YouTube; only the extra settings are missing.
        setState(() {
          _uploadedId = videoId;
          _partialSteps = _stepNames(l10n, e);
        });
        return;
      }
      setState(() => _busy = false);
      final switched = await _showError(e);
      // After switching to a working account, upload right away so the
      // user doesn't have to tap again.
      if (switched && mounted) await _submit();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyPhase = _UploadBusyPhase.idle;
          _busyProgress = 0;
        });
      }
    }
  }

  String _stepNames(AppLocalizations l10n, Object error) {
    final step = error is YouTubeApiException ? error.step : '';
    return switch (step) {
      'thumbnail' => l10n.uploadStepThumbnail,
      _ => l10n.uploadStepThumbnail,
    };
  }

  /// Applies post-upload settings that still work with `youtube.upload`
  /// (custom thumbnail). Returns failed step names, or null on success.
  Future<String?> _applyDetails({
    required String token,
    required String videoId,
  }) async {
    final l10n = context.l10n;
    final thumbnail = _thumbnailPath;
    if (thumbnail == null) return null;
    try {
      await _upload.setThumbnail(
        accessToken: token,
        videoId: videoId,
        imagePath: thumbnail,
      );
      return null;
    } catch (error) {
      debugPrint('[YouTubeUpload] 후속 단계 실패: $error');
      return l10n.uploadStepThumbnail;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final preview = _preview;

    final uploadedId = _uploadedId;
    if (uploadedId != null) return _buildDone(l10n, uploadedId);

    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return UploadAmbientScaffold(
      title: l10n.uploadShorts,
      bottom: keyboardOpen ? _buildKeyboardDismissBar(l10n) : null,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          _buildAccountCard(l10n),
          const SizedBox(height: 14),
          UploadSurfaceCard(
            child: _buildPreview(l10n, preview),
          ),
          const SizedBox(height: 14),
          UploadSurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                UploadSectionLabel(l10n.uploadVisibility),
                const SizedBox(height: 10),
                UploadChoiceChips<String>(
                  value: _privacy,
                  enabled: !_busy,
                  options: [
                    ('public', l10n.privacyPublic),
                    ('unlisted', l10n.privacyUnlisted),
                    ('private', l10n.privacyPrivate),
                  ],
                  onChanged: (value) => setState(() => _privacy = value),
                ),
                const SizedBox(height: 18),
                UploadSectionLabel(
                  l10n.uploadAudience,
                  help: l10n.uploadAudienceHelp,
                ),
                const SizedBox(height: 10),
                UploadChoiceChips<bool>(
                  value: _madeForKids,
                  enabled: !_busy,
                  options: [
                    (false, l10n.uploadAudienceNotForKids),
                    (true, l10n.uploadAudienceForKids),
                  ],
                  onChanged: (value) => setState(() => _madeForKids = value),
                ),
              ],
            ),
          ),
          if (_moreOpen) ...[
            const SizedBox(height: 14),
            UploadSurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _relatedController,
                    enabled: !_busy,
                    textInputAction: TextInputAction.done,
                    onEditingComplete: _dismissKeyboard,
                    style: GoogleFonts.dmSans(color: AppTheme.ink),
                    decoration: UploadFormChrome.fieldDecoration(
                      label: l10n.uploadRelatedVideo,
                      hint: l10n.uploadRelatedVideoHint,
                    ),
                  ),
                  const SizedBox(height: 8),
                  UploadToggleTile(
                    title: l10n.uploadPaidPromotion,
                    subtitle: l10n.uploadPaidPromotionHelp,
                    value: _paidPromotion,
                    enabled: !_busy,
                    onChanged: (value) =>
                        setState(() => _paidPromotion = value),
                  ),
                  UploadToggleTile(
                    title: l10n.uploadAlteredContent,
                    subtitle: l10n.uploadAlteredContentHelp,
                    value: _syntheticMedia,
                    enabled: !_busy,
                    onChanged: (value) =>
                        setState(() => _syntheticMedia = value),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _tagsController,
                    enabled: !_busy,
                    textInputAction: TextInputAction.done,
                    onEditingComplete: _dismissKeyboard,
                    style: GoogleFonts.dmSans(color: AppTheme.ink),
                    decoration: UploadFormChrome.fieldDecoration(
                      label: l10n.uploadTags,
                      hint: l10n.uploadTagsHint,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 8),
          UploadSurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                UploadCrossPostToggle(
                  title: l10n.crossPostAlsoTikTok,
                  value: _alsoTikTok,
                  enabled: !_busy,
                  onChanged: _setAlsoTikTok,
                ),
                if (_alsoTikTok) ...[
                  const SizedBox(height: 8),
                  _buildTikTokCrossAccount(l10n),
                  if (_tikTokCreator != null) ...[
                    const SizedBox(height: 12),
                    UploadSectionLabel(l10n.uploadVisibility),
                    const SizedBox(height: 8),
                    UploadChoiceChips<String>(
                      value: _tikTokPrivacy,
                      enabled: !_busy,
                      options: [
                        for (final option in _tikTokCreator!.privacyOptions)
                          (option, _tikTokPrivacyLabel(l10n, option)),
                      ],
                      onChanged: (value) {
                        if (_tikTokDisclose &&
                            _tikTokBranded &&
                            value == _tikTokSelfOnly) {
                          return;
                        }
                        setState(() => _tikTokPrivacy = value);
                      },
                    ),
                    const SizedBox(height: 8),
                    UploadToggleTile(
                      title: l10n.tiktokAllowComment,
                      value: _tikTokAllowComment,
                      enabled: !_busy &&
                          !(_tikTokCreator?.commentDisabled ?? false),
                      onChanged: (v) =>
                          setState(() => _tikTokAllowComment = v),
                    ),
                    UploadToggleTile(
                      title: l10n.tiktokAllowDuet,
                      value: _tikTokAllowDuet,
                      enabled:
                          !_busy && !(_tikTokCreator?.duetDisabled ?? false),
                      onChanged: (v) => setState(() => _tikTokAllowDuet = v),
                    ),
                    UploadToggleTile(
                      title: l10n.tiktokAllowStitch,
                      value: _tikTokAllowStitch,
                      enabled: !_busy &&
                          !(_tikTokCreator?.stitchDisabled ?? false),
                      onChanged: (v) =>
                          setState(() => _tikTokAllowStitch = v),
                    ),
                    UploadToggleTile(
                      title: l10n.tiktokDisclose,
                      subtitle: l10n.tiktokDiscloseHelp,
                      value: _tikTokDisclose,
                      enabled: !_busy,
                      onChanged: (v) => setState(() {
                        _tikTokDisclose = v;
                        if (!v) {
                          _tikTokYourBrand = false;
                          _tikTokBranded = false;
                        }
                      }),
                    ),
                    if (_tikTokDisclose) ...[
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        activeColor: AppTheme.accent,
                        title: Text(
                          l10n.tiktokYourBrand,
                          style: GoogleFonts.dmSans(
                            fontWeight: FontWeight.w600,
                            color: AppTheme.ink,
                          ),
                        ),
                        value: _tikTokYourBrand,
                        onChanged: _busy
                            ? null
                            : (v) => setState(
                                  () => _tikTokYourBrand = v ?? false,
                                ),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        activeColor: AppTheme.accent,
                        title: Text(
                          l10n.tiktokBrandedContent,
                          style: GoogleFonts.dmSans(
                            fontWeight: FontWeight.w600,
                            color: AppTheme.ink,
                          ),
                        ),
                        value: _tikTokBranded,
                        onChanged: _busy
                            ? null
                            : (v) => setState(
                                  () => _tikTokBranded = v ?? false,
                                ),
                      ),
                    ],
                    TextButton.icon(
                      onPressed: _busy ? null : _pickTikTokCover,
                      icon: const Icon(Icons.image_outlined, size: 18),
                      label: Text(
                        '${l10n.uploadThumbnailSelect} · '
                        '${Duration(milliseconds: _tikTokCoverMs).inSeconds}s',
                      ),
                    ),
                  ] else if (!_tikTokAccountLoading)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        l10n.tiktokConnectHelp,
                        style: GoogleFonts.dmSans(
                          fontSize: 13,
                          color: AppTheme.muted,
                          height: 1.35,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _busy
                ? null
                : () => setState(() => _moreOpen = !_moreOpen),
            icon: Icon(
              _moreOpen ? Icons.expand_less : Icons.expand_more,
              color: AppTheme.muted,
            ),
            label: Text(
              _moreOpen ? l10n.uploadFewerDetails : l10n.uploadMoreDetails,
              style: GoogleFonts.dmSans(
                color: AppTheme.muted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 8),
          UploadGradientButton(
            label: _alsoTikTok
                ? l10n.uploadShortsAndTikTok
                : l10n.uploadShorts,
            onPressed: _busy ? null : _submit,
            busy: _busy,
            busyProgress: _busy ? _overallBusyProgress : null,
            busyLabel: UploadBusyStatusLabel(_busyStatusText(l10n)),
          ),
        ],
      ),
    );
  }

  String _tikTokPrivacyLabel(AppLocalizations l10n, String option) {
    return switch (option) {
      'PUBLIC_TO_EVERYONE' => l10n.tiktokPrivacyPublic,
      'MUTUAL_FOLLOW_FRIENDS' => l10n.tiktokPrivacyFriends,
      'FOLLOWER_OF_CREATOR' => l10n.tiktokPrivacyFollowers,
      _tikTokSelfOnly => l10n.tiktokPrivacySelf,
      _ => option,
    };
  }

  Widget _buildTikTokCrossAccount(AppLocalizations l10n) {
    final creator = _tikTokCreator;
    return Row(
      children: [
        CircleAvatar(
          radius: 16,
          backgroundColor: AppTheme.surfaceElevated,
          foregroundImage: creator == null || creator.avatarUrl.isEmpty
              ? null
              : NetworkImage(creator.avatarUrl),
          child: const Icon(
            Icons.person_outline,
            size: 18,
            color: AppTheme.muted,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            creator == null
                ? (_tikTokAccountLoading ? '' : l10n.uploadAccountNone)
                : (creator.nickname.isEmpty
                    ? '@${creator.username}'
                    : creator.nickname),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.dmSans(
              fontWeight: FontWeight.w700,
              color: AppTheme.ink,
            ),
          ),
        ),
        if (_tikTokAccountLoading)
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          TextButton(
            onPressed: _busy
                ? null
                : () => _connectTikTok(fresh: creator != null),
            child: Text(
              creator == null
                  ? l10n.uploadAccountConnect
                  : l10n.uploadAccountSwitch,
              style: GoogleFonts.dmSans(
                color: AppTheme.accentCyan,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
    );
  }

  String _privacyLabel(AppLocalizations l10n) {
    return switch (_privacy) {
      'private' => l10n.privacyPrivate,
      'unlisted' => l10n.privacyUnlisted,
      _ => l10n.privacyPublic,
    };
  }

  /// Result after a successful upload: stays on screen with the watch link
  /// instead of silently going back.
  Widget _buildDone(AppLocalizations l10n, String videoId) {
    final theme = Theme.of(context);
    // Generic watch URL — YouTube routes Shorts itself when applicable.
    final link = 'https://youtube.com/watch?v=$videoId';
    final partial = _partialSteps;
    final thumbnail = _thumbnailPath;
    final preview = _preview;
    void close() => Navigator.of(context).pop();

    return UploadAmbientScaffold(
      key: const Key('youtube-upload-done'),
      automaticallyImplyLeading: false,
      title: l10n.uploadShorts,
      actions: [
        TextButton(
          onPressed: close,
          child: Text(
            l10n.uploadDoneClose,
            style: GoogleFonts.dmSans(
              color: AppTheme.ink,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          const Center(child: UploadCheckBadge()),
          const SizedBox(height: 18),
          Text(
            l10n.uploadDoneTitle,
            textAlign: TextAlign.center,
            style: GoogleFonts.spaceGrotesk(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: AppTheme.ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.uploadDoneVisibility(_privacyLabel(l10n)),
            textAlign: TextAlign.center,
            style: GoogleFonts.dmSans(color: AppTheme.muted, fontSize: 14),
          ),
          if (_crossPostNote != null) ...[
            const SizedBox(height: 8),
            Text(
              _crossPostNote!,
              textAlign: TextAlign.center,
              style: GoogleFonts.dmSans(color: AppTheme.muted, fontSize: 13),
            ),
          ],
          const SizedBox(height: 22),
          UploadSurfaceCard(
            padding: EdgeInsets.zero,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _copyLink(l10n, link),
                borderRadius: BorderRadius.circular(16),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 45,
                          height: 80,
                          child: thumbnail != null
                              ? Image.file(File(thumbnail), fit: BoxFit.cover)
                              : preview != null && preview.value.isInitialized
                              ? FittedBox(
                                  fit: BoxFit.cover,
                                  child: SizedBox(
                                    width: preview.value.size.width,
                                    height: preview.value.size.height,
                                    child: VideoPlayer(preview),
                                  ),
                                )
                              : ColoredBox(
                                  color: Colors.black26,
                                  child: Icon(
                                    Icons.smart_display_outlined,
                                    color: theme.hintColor,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _titleFromCaption(_descriptionController.text),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.dmSans(
                                fontWeight: FontWeight.w700,
                                color: AppTheme.ink,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              link,
                              key: const Key('youtube-upload-link'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.dmSans(
                                fontSize: 12,
                                color: AppTheme.accentCyan,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.copy_rounded,
                        size: 18,
                        color: AppTheme.muted,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            l10n.uploadDoneProcessing,
            style: GoogleFonts.dmSans(color: AppTheme.muted, fontSize: 12),
          ),
          if (partial != null) ...[
            const SizedBox(height: 12),
            DecoratedBox(
              decoration: BoxDecoration(
                color: AppTheme.accentWarm.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppTheme.accentWarm.withValues(alpha: 0.35),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.info_outline,
                      size: 18,
                      color: AppTheme.accentWarm,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.uploadPartialDone(partial),
                        style: GoogleFonts.dmSans(
                          fontSize: 13,
                          color: AppTheme.ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 28),
          UploadGradientButton(
            label: l10n.uploadDoneOpen,
            onPressed: () => launchUrl(
              Uri.parse(link),
              mode: LaunchMode.externalApplication,
            ),
          ),
          if (_tikTokCrossOpenUrl != null) ...[
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () => launchUrl(
                Uri.parse(_tikTokCrossOpenUrl!),
                mode: LaunchMode.externalApplication,
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                foregroundColor: AppTheme.ink,
              ),
              child: Text(
                l10n.tiktokOpen,
                style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _copyLink(l10n, link),
                  icon: const Icon(Icons.link_rounded, size: 18),
                  label: Text(l10n.uploadDoneCopy),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => ExportShareService().shareText(link),
                  icon: const Icon(Icons.ios_share_rounded, size: 18),
                  label: Text(l10n.uploadDoneShare),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _copyLink(AppLocalizations l10n, String link) async {
    await Clipboard.setData(ClipboardData(text: link));
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    showLoggedSnackBar(context, l10n.uploadDoneCopied);
  }

  /// Shows which channel the video goes to, with a one-tap way to use a
  /// different Google account.
  Widget _buildAccountCard(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final account = _account;
    final name = account?.displayName?.trim();
    final photo = account?.photoUrl;
    final Widget avatar = CircleAvatar(
      radius: 18,
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
      foregroundImage: photo == null ? null : NetworkImage(photo),
      child: Icon(
        account == null ? Icons.person_outline : Icons.person,
        size: 20,
        color: theme.hintColor,
      ),
    );
    return UploadSurfaceCard(
      key: const Key('youtube-account-card'),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      child: Row(
        children: [
          avatar,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.uploadAccountTitle,
                  style: GoogleFonts.dmSans(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.muted,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 2),
                if (account == null)
                  Text(
                    _accountLoading ? '' : l10n.uploadAccountNone,
                    style: GoogleFonts.dmSans(color: AppTheme.ink),
                  )
                else ...[
                  Text(
                    name == null || name.isEmpty ? account.email : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.dmSans(
                      fontWeight: FontWeight.w700,
                      color: AppTheme.ink,
                    ),
                  ),
                  if (name != null && name.isNotEmpty)
                    Text(
                      account.email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.dmSans(
                        fontSize: 12,
                        color: AppTheme.muted,
                      ),
                    ),
                ],
              ],
            ),
          ),
          if (_accountLoading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            TextButton(
              key: const Key('youtube-account-change'),
              onPressed: _busy ? null : _changeAccount,
              child: Text(
                account == null
                    ? l10n.uploadAccountConnect
                    : l10n.uploadAccountSwitch,
                style: GoogleFonts.dmSans(
                  color: AppTheme.accentCyan,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPreview(AppLocalizations l10n, VideoPlayerController? preview) {
    final ready =
        preview != null && preview.value.isInitialized && !_previewFailed;
    final showStill = _thumbnailPath != null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _thumbnailFrame(preview, ready, showStill),
        const SizedBox(width: 16),
        Expanded(
          child: TextField(
            controller: _descriptionController,
            enabled: !_busy,
            minLines: 1,
            maxLines: 4,
            textInputAction: TextInputAction.newline,
            style: GoogleFonts.spaceGrotesk(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: AppTheme.ink,
              height: 1.25,
            ),
            decoration: InputDecoration(
              hintText: l10n.uploadShortsCaption,
              hintStyle: GoogleFonts.spaceGrotesk(
                fontSize: 20,
                fontWeight: FontWeight.w500,
                color: AppTheme.muted.withValues(alpha: 0.7),
              ),
              border: InputBorder.none,
              isCollapsed: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      ],
    );
  }

  void _dismissKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// Sits just above the system keyboard while a field is focused.
  Widget _buildKeyboardDismissBar(AppLocalizations l10n) {
    return Material(
      color: AppTheme.surfaceElevated,
      elevation: 6,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 44,
          child: Row(
            children: [
              const Spacer(),
              TextButton(
                onPressed: _dismissKeyboard,
                child: Text(
                  l10n.uploadDoneClose,
                  style: GoogleFonts.dmSans(
                    color: AppTheme.accentCyan,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _thumbnailFrame(
    VideoPlayerController? preview,
    bool ready,
    bool showStill,
  ) {
    return SizedBox(
      width: 78,
      height: 138,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: ColoredBox(
          color: AppTheme.surface,
          child: ready && preview != null
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    if (showStill)
                      Image.file(
                        File(_thumbnailPath!),
                        key: ValueKey(_thumbnailPath),
                        fit: BoxFit.cover,
                        gaplessPlayback: false,
                      )
                    else
                      FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: preview.value.size.width,
                          height: preview.value.size.height,
                          child: VideoPlayer(preview),
                        ),
                      ),
                    Positioned(
                      left: 6,
                      top: 6,
                      child: _editThumbnailButton(ready),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 6,
                      child: Center(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.72),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            child: Text(
                              _thumbnailDurationLabel(),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                height: 1.2,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : Center(
                  child: _previewFailed
                      ? const Icon(Icons.broken_image_outlined, size: 20)
                      : const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                ),
        ),
      ),
    );
  }

  Widget _editThumbnailButton(bool ready) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: !ready || _busy ? null : _editThumbnail,
        child: const SizedBox(
          width: 26,
          height: 26,
          child: Icon(Icons.edit, size: 15, color: Colors.white),
        ),
      ),
    );
  }
}

enum _UploadBusyPhase {
  idle,
  exporting,
  uploadingYouTube,
  finishingYouTube,
  uploadingTikTok,
  processingTikTok,
}
