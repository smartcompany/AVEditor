import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/screens/tiktok_cover_picker_screen.dart';
import 'package:aveditor/services/analytics_service.dart';
import 'package:aveditor/services/app_settings_service.dart';
import 'package:aveditor/services/export_service.dart';
import 'package:aveditor/services/tiktok_auth_service.dart';
import 'package:aveditor/services/tiktok_post_service.dart';
import 'package:aveditor/services/video_filmstrip_cache.dart';
import 'package:aveditor/services/video_frame_grab.dart';
import 'package:aveditor/services/video_probe_service.dart';
import 'package:aveditor/services/youtube_auth_service.dart';
import 'package:aveditor/services/youtube_upload_service.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/utils/cross_post_privacy.dart';
import 'package:aveditor/utils/logged_snackbar.dart';
import 'package:aveditor/widgets/upload_form_chrome.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

/// Direct Post to TikTok (Content Posting API), following TikTok's required
/// UX: creator shown, privacy chosen by the user with no default,
/// interactions off by default, commercial disclosure, consent text.
class TikTokUploadScreen extends StatefulWidget {
  const TikTokUploadScreen({
    super.key,
    required this.videoPath,
    this.project,
    this.onFinishInApp,
    this.auth,
    this.posts,
  });

  /// Exported video file to post.
  final String videoPath;

  /// Optional project for YouTube cross-post (reuses export metadata).
  final VideoProject? project;

  /// Optional fallback: hand the video to the TikTok app (Share Kit).
  final Future<void> Function()? onFinishInApp;

  final TikTokAuthService? auth;
  final TikTokPostService? posts;

  @override
  State<TikTokUploadScreen> createState() => _TikTokUploadScreenState();
}

const _musicPolicyUrl =
    'https://www.tiktok.com/legal/page/global/music-usage-confirmation/en';
const _brandPolicyUrl = 'https://www.tiktok.com/legal/page/global/bc-policy/en';
const _selfOnly = 'SELF_ONLY';

/// Maps a failure to a message key; exposed for tests.
@visibleForTesting
enum TikTokErrorKind {
  cancelled,
  serverNotConfigured,
  denied,
  authExpired,
  privateOnly,
  rateLimited,
  banned,
  privacyMismatch,
  network,
  unknown,
}

@visibleForTesting
TikTokErrorKind classifyTikTokError(Object error) {
  if (error is TikTokAuthException) {
    return switch (error.code) {
      'cancelled' => TikTokErrorKind.cancelled,
      'server_not_configured' => TikTokErrorKind.serverNotConfigured,
      'access_denied' => TikTokErrorKind.denied,
      'network' => TikTokErrorKind.network,
      'invalid_grant' => TikTokErrorKind.authExpired,
      _ => TikTokErrorKind.unknown,
    };
  }
  if (error is TikTokApiException) {
    return switch (error.code) {
      'access_token_invalid' || 'http_401' => TikTokErrorKind.authExpired,
      'scope_not_authorized' => TikTokErrorKind.denied,
      'unaudited_client_can_only_post_to_private_accounts' =>
        TikTokErrorKind.privateOnly,
      'spam_risk_too_many_posts' ||
      'spam_risk_too_many_pending_share' ||
      'rate_limit_exceeded' ||
      'reached_active_user_cap' => TikTokErrorKind.rateLimited,
      'spam_risk_user_banned_from_posting' => TikTokErrorKind.banned,
      'privacy_level_option_mismatch' => TikTokErrorKind.privacyMismatch,
      _ => TikTokErrorKind.unknown,
    };
  }
  if (error is SocketException || error is HttpException) {
    return TikTokErrorKind.network;
  }
  return TikTokErrorKind.unknown;
}

class _TikTokUploadScreenState extends State<TikTokUploadScreen> {
  late final TikTokAuthService _auth = widget.auth ?? TikTokAuthService();
  late final TikTokPostService _posts = widget.posts ?? TikTokPostService();
  final _captionController = TextEditingController();

  VideoPlayerController? _preview;
  TikTokSession? _session;
  TikTokCreatorInfo? _creator;
  bool _accountLoading = true;

  String? _privacy;
  bool _allowComment = false;
  bool _allowDuet = false;
  bool _allowStitch = false;
  bool _disclose = false;
  bool _yourBrand = false;
  bool _branded = false;

  bool _busy = false;
  _TikTokBusyPhase _busyPhase = _TikTokBusyPhase.idle;
  double _busyProgress = 0;
  TikTokPublishStatus? _done;
  String? _crossPostNote;

  /// YouTube watch URL after a successful cross-post (done screen).
  String? _youtubeCrossOpenUrl;

  /// Cover frame for Direct Post (`video_cover_timestamp_ms`).
  var _coverTimestampMs = 0;
  Uint8List? _coverBytes;

  // --- Optional YouTube cross-post ---
  var _alsoYouTube = false;
  final _youtubeAuth = YouTubeAuthService();
  final _youtubeUpload = YouTubeUploadService();
  final _export = ExportService();
  final _settings = const AppSettingsService();
  GoogleSignInAccount? _youtubeAccount;
  var _youtubeAccountLoading = false;
  var _youtubePrivacy = 'public';
  var _youtubeMadeForKids = false;
  var _youtubePaidPromotion = false;
  var _youtubeSyntheticMedia = false;

  @override
  void initState() {
    super.initState();
    _openPreview();
    _restoreAccount();
  }

  @override
  void dispose() {
    _preview?.dispose();
    _captionController.dispose();
    super.dispose();
  }

  Future<void> _openPreview() async {
    final controller = VideoPlayerController.file(File(widget.videoPath));
    _preview = controller;
    try {
      await controller.initialize();
      if (!mounted) return;
      setState(() {});
      unawaited(_refreshCoverStill());
    } catch (error) {
      debugPrint('[TikTokUpload] 미리보기 실패: $error');
    }
  }

  Future<void> _refreshCoverStill() async {
    final bytes = await VideoFilmstripCache.instance.getBytes(
      video: widget.videoPath,
      timeMs: _coverTimestampMs,
      maxHeight: VideoFilmstripCache.stripMaxHeight,
      maxWidth: VideoFilmstripCache.stripMaxHeight,
      quality: VideoFilmstripCache.stripQuality,
    );
    if (!mounted || bytes == null) return;
    setState(() => _coverBytes = bytes);
  }

  Future<void> _editCover() async {
    if (_busy) return;
    final nav = Navigator.of(context);
    await _preview?.pause();
    if (!mounted) return;
    final picked = await nav.push<int>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => TikTokCoverPickerScreen(
          videoPath: widget.videoPath,
          initialMs: _coverTimestampMs,
        ),
      ),
    );
    if (!mounted || picked == null) return;
    setState(() => _coverTimestampMs = picked);
    await _refreshCoverStill();
  }

  Future<void> _restoreAccount() async {
    final session = await _auth.currentSession();
    await _loadCreator(session);
  }

  Future<void> _loadCreator(TikTokSession? session) async {
    if (session == null) {
      if (!mounted) return;
      setState(() {
        _session = null;
        _creator = null;
        _accountLoading = false;
      });
      return;
    }
    try {
      final creator = await _posts.creatorInfo(session.accessToken);
      if (!mounted) return;
      setState(() {
        _session = session;
        _creator = creator;
        // Options can differ per account; drop a choice it doesn't offer.
        if (!creator.privacyOptions.contains(_privacy)) _privacy = null;
        if (creator.commentDisabled) _allowComment = false;
        if (creator.duetDisabled) _allowDuet = false;
        if (creator.stitchDisabled) _allowStitch = false;
      });
    } catch (error) {
      debugPrint('[TikTokUpload] creator_info 실패: $error');
      if (!mounted) return;
      setState(() {
        _session = null;
        _creator = null;
      });
      await _showError(error);
    } finally {
      if (mounted) setState(() => _accountLoading = false);
    }
  }

  Future<void> _connect({bool fresh = false}) async {
    setState(() => _accountLoading = true);
    try {
      if (fresh) await _auth.signOut();
      final session = await _auth.signIn(freshAccount: fresh);
      AnalyticsService.instance.log('tiktok_account_connected');
      await _loadCreator(session);
    } catch (error) {
      debugPrint('[TikTokUpload] 로그인 실패: $error');
      if (!mounted) return;
      final current = await _auth.currentSession();
      if (!mounted) return;
      setState(() {
        _accountLoading = false;
        if (current == null) {
          _session = null;
          _creator = null;
        }
      });
      await _showError(error, offerSwitch: false);
    }
  }

  Duration get _duration => _preview?.value.duration ?? Duration.zero;

  bool get _tooLong {
    final max = _creator?.maxDurationSeconds;
    return max != null && _duration.inSeconds > max;
  }

  bool get _disclosureIncomplete => _disclose && !_yourBrand && !_branded;

  bool get _canPost =>
      !_busy &&
      _creator != null &&
      _privacy != null &&
      !_tooLong &&
      !_disclosureIncomplete &&
      !(_disclose && _branded && _privacy == _selfOnly) &&
      (!_alsoYouTube || _youtubeAccount != null);

  Future<void> _setAlsoYouTube(bool value) async {
    setState(() => _alsoYouTube = value);
    if (!value) return;
    if (_privacy != null) {
      _youtubePrivacy = CrossPostPrivacy.tikTokToYouTube(_privacy!);
    }
    setState(() => _youtubeAccountLoading = true);
    try {
      final account = await _youtubeAuth.currentAccount();
      if (!mounted) return;
      setState(() {
        _youtubeAccount = account;
        _youtubeAccountLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _youtubeAccount = null;
        _youtubeAccountLoading = false;
      });
    }
  }

  Future<void> _connectYouTube({bool fresh = false}) async {
    setState(() => _youtubeAccountLoading = true);
    try {
      if (fresh) await _youtubeAuth.signOut();
      await _youtubeAuth.signIn();
      final account = await _youtubeAuth.currentAccount();
      if (!mounted) return;
      setState(() => _youtubeAccount = account);
    } catch (error) {
      debugPrint('[TikTokUpload] YouTube connect failed: $error');
      if (!mounted) return;
      showLoggedSnackBar(context, error.toString(), error: error);
    } finally {
      if (mounted) setState(() => _youtubeAccountLoading = false);
    }
  }

  Future<VideoProject> _projectForYouTube() async {
    final existing = widget.project;
    if (existing != null) return existing;
    var duration = await const VideoProbeService().readDuration(
          widget.videoPath,
        ) ??
        Duration.zero;
    if (duration <= Duration.zero) {
      duration = _duration > Duration.zero
          ? _duration
          : const Duration(seconds: 1);
    }
    return VideoProject(
      id: '_tiktok_cross_yt',
      sourcePath: widget.videoPath,
      duration: duration,
    );
  }

  void _setBusyProgress(_TikTokBusyPhase phase, [double progress = 0]) {
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
      _TikTokBusyPhase.uploadingTikTok => _alsoYouTube
          ? l10n.crossPostUploadingTikTok(percent)
          : l10n.tiktokUploading(percent),
      _TikTokBusyPhase.processingTikTok => l10n.tiktokProcessing,
      _TikTokBusyPhase.uploadingYouTube =>
        l10n.crossPostUploadingYouTube(percent),
      _TikTokBusyPhase.finishingYouTube => l10n.youtubeFinishing,
      _TikTokBusyPhase.idle => l10n.tiktokUploading(0),
    };
  }

  /// Button fill: one platform = full bar; dual-post splits 50/50.
  double get _overallBusyProgress {
    final p = _busyProgress.clamp(0.0, 1.0);
    if (_alsoYouTube) {
      return switch (_busyPhase) {
        _TikTokBusyPhase.idle => 0,
        _TikTokBusyPhase.uploadingTikTok => p * 0.48,
        _TikTokBusyPhase.processingTikTok => 0.50,
        _TikTokBusyPhase.uploadingYouTube => 0.50 + p * 0.42,
        _TikTokBusyPhase.finishingYouTube => 0.96,
      };
    }
    return switch (_busyPhase) {
      _TikTokBusyPhase.idle => 0,
      _TikTokBusyPhase.uploadingTikTok => p * 0.9,
      _TikTokBusyPhase.processingTikTok => 0.95,
      _TikTokBusyPhase.uploadingYouTube ||
      _TikTokBusyPhase.finishingYouTube => 1,
    };
  }

  /// Returns the uploaded YouTube video id.
  Future<String> _postToYouTube() async {
    final l10n = context.l10n;
    final caption = _captionController.text.trim();
    final title = () {
      final line = caption
          .split('\n')
          .map((part) => part.trim())
          .firstWhere((part) => part.isNotEmpty, orElse: () => '');
      if (line.isEmpty) return l10n.appTitle;
      return line.length <= 100 ? line : line.substring(0, 100);
    }();
    final signedIn = await _youtubeAuth.isSignedIn;
    if (!signedIn) {
      await _youtubeAuth.signIn();
      final account = await _youtubeAuth.currentAccount();
      if (mounted) setState(() => _youtubeAccount = account);
    }
    final token = await _youtubeAuth.accessToken();
    final project = await _projectForYouTube();
    var path = widget.videoPath;
    if (!await File(path).exists()) {
      final quality = await _settings.getExportQualityProfile();
      path = await _export.exportForPreset(project, quality: quality);
    }
    _setBusyProgress(_TikTokBusyPhase.uploadingYouTube, 0);
    final videoId = await _youtubeUpload.uploadProject(
      project: project,
      exportedPath: path,
      accessToken: token,
      title: title,
      description: caption,
      privacyStatus: _youtubePrivacy,
      madeForKids: _youtubeMadeForKids,
      containsSyntheticMedia: _youtubeSyntheticMedia,
      paidPromotion: _youtubePaidPromotion,
      onProgress: (progress) =>
          _setBusyProgress(_TikTokBusyPhase.uploadingYouTube, progress),
    );
    _setBusyProgress(_TikTokBusyPhase.finishingYouTube);
    final thumb = await const VideoFrameGrab().jpegFile(
      video: widget.videoPath,
      timeMs: _coverTimestampMs,
      maxHeight: 1280,
      maxWidth: 1280,
      quality: 90,
    );
    if (thumb != null) {
      try {
        await _youtubeUpload.setThumbnail(
          accessToken: token,
          videoId: videoId,
          imagePath: thumb,
        );
      } catch (error) {
        debugPrint('[TikTokUpload] YouTube thumbnail failed: $error');
      }
    }
    return videoId;
  }

  Future<void> _submit() async {
    final session = _session;
    final privacy = _privacy;
    final l10n = context.l10n;
    if (session == null || privacy == null || !_canPost) return;
    if (_alsoYouTube && _youtubeAccount == null) {
      showLoggedSnackBar(context, l10n.uploadAccountNone);
      return;
    }
    setState(() {
      _busy = true;
      _busyPhase = _TikTokBusyPhase.uploadingTikTok;
      _busyProgress = 0;
      _crossPostNote = null;
    });
    await _preview?.pause();
    try {
      final maxCoverMs =
          (_duration.inMilliseconds - 1).clamp(0, 1 << 30);
      final coverMs = _coverTimestampMs.clamp(0, maxCoverMs);
      final info = TikTokPostInfo(
        title: _captionController.text.trim(),
        privacyLevel: privacy,
        allowComment: _allowComment,
        allowDuet: _allowDuet,
        allowStitch: _allowStitch,
        coverTimestampMs: coverMs,
        brandOrganic: _disclose && _yourBrand,
        brandedContent: _disclose && _branded,
      );
      final publishId = await _posts.publish(
        accessToken: session.accessToken,
        file: File(widget.videoPath),
        info: info,
        onProgress: (value) =>
            _setBusyProgress(_TikTokBusyPhase.uploadingTikTok, value),
      );
      if (!mounted) return;
      _setBusyProgress(_TikTokBusyPhase.processingTikTok);
      final status = await _posts.waitForPublish(
        session.accessToken,
        publishId,
      );
      if (status.state == TikTokPublishState.failed) {
        throw TikTokApiException('publish_failed', message: status.failReason);
      }
      AnalyticsService.instance.log('tiktok_post_completed', {
        'privacy': privacy,
        'alsoYouTube': _alsoYouTube,
      });

      String? crossNote;
      String? youtubeOpenUrl;
      if (_alsoYouTube) {
        try {
          final videoId = await _postToYouTube();
          AnalyticsService.instance.log('youtube_upload_completed', {
            'from': 'tiktok_cross',
          });
          crossNote = l10n.crossPostYouTubeOk;
          youtubeOpenUrl = 'https://youtube.com/watch?v=$videoId';
        } catch (error) {
          debugPrint('[TikTokUpload] YouTube cross-post failed: $error');
          crossNote = l10n.crossPostYouTubeFailed('$error');
        }
      }

      if (!mounted) return;
      setState(() {
        _done = status;
        _crossPostNote = crossNote;
        _youtubeCrossOpenUrl = youtubeOpenUrl;
      });
    } catch (error, stack) {
      debugPrint('[TikTokUpload] 게시 실패: $error\n$stack');
      if (!mounted) return;
      setState(() => _busy = false);
      await _showError(error);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyPhase = _TikTokBusyPhase.idle;
          _busyProgress = 0;
        });
      }
    }
  }

  String _errorMessage(AppLocalizations l10n, TikTokErrorKind kind, Object e) {
    return switch (kind) {
      TikTokErrorKind.serverNotConfigured => l10n.tiktokErrServer,
      TikTokErrorKind.denied => l10n.tiktokErrDenied,
      TikTokErrorKind.authExpired => l10n.tiktokErrAuth,
      TikTokErrorKind.privateOnly => l10n.tiktokErrPrivateOnly,
      TikTokErrorKind.rateLimited => l10n.tiktokErrSpam,
      TikTokErrorKind.banned => l10n.tiktokErrBanned,
      TikTokErrorKind.privacyMismatch => l10n.tiktokErrPrivacyMismatch,
      TikTokErrorKind.network => l10n.uploadErrNetwork,
      TikTokErrorKind.cancelled || TikTokErrorKind.unknown =>
        e is TikTokApiException && e.code == 'publish_failed'
            ? l10n.tiktokErrFailed
            : l10n.uploadErrUnknown,
    };
  }

  String? _errorCode(Object error, TikTokErrorKind kind) {
    if (error is TikTokAuthException &&
        kind != TikTokErrorKind.cancelled &&
        error.message.isNotEmpty) {
      return '${error.code} ${error.message}';
    }
    if (kind != TikTokErrorKind.unknown) return null;
    if (error is TikTokApiException) {
      return [
        error.code,
        error.message,
        error.logId,
      ].where((part) => part.isNotEmpty).join(' ');
    }
    if (error is TikTokAuthException) return 'auth ${error.code}';
    return error.runtimeType.toString();
  }

  Future<void> _showError(Object error, {bool offerSwitch = true}) async {
    final kind = classifyTikTokError(error);
    if (kind == TikTokErrorKind.cancelled || !mounted) return;
    if (kind == TikTokErrorKind.authExpired) {
      await _auth.signOut();
      if (mounted) {
        setState(() {
          _session = null;
          _creator = null;
        });
      }
    }
    if (!mounted) return;
    final l10n = context.l10n;
    final code = _errorCode(error, kind);
    final canSwitch =
        offerSwitch &&
        (kind == TikTokErrorKind.authExpired || kind == TikTokErrorKind.banned);
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
              Text(_errorMessage(l10n, kind, error)),
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
                child: Text(l10n.tiktokSwitchAccount),
              ),
          ],
        );
      },
    );
    if (switchNow == true && mounted) await _connect(fresh: true);
  }

  String _privacyLabel(AppLocalizations l10n, String option) {
    return switch (option) {
      'PUBLIC_TO_EVERYONE' => l10n.tiktokPrivacyPublic,
      'MUTUAL_FOLLOW_FRIENDS' => l10n.tiktokPrivacyFriends,
      'FOLLOWER_OF_CREATOR' => l10n.tiktokPrivacyFollowers,
      _selfOnly => l10n.tiktokPrivacySelf,
      _ => option,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final done = _done;
    if (done != null) return _buildDone(l10n, done);
    final creator = _creator;

    final privacyOptions = creator?.privacyOptions ?? const <String>[];
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return PopScope(
      canPop: !_busy,
      child: UploadAmbientScaffold(
        title: l10n.tiktokUploadTitle,
        bottom: keyboardOpen ? _buildKeyboardDismissBar(l10n) : null,
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            _buildAccountCard(l10n),
            const SizedBox(height: 14),
            if (creator == null && !_accountLoading)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  l10n.tiktokConnectHelp,
                  style: GoogleFonts.dmSans(
                    fontSize: 13,
                    color: AppTheme.muted,
                    height: 1.35,
                  ),
                ),
              ),
            UploadSurfaceCard(child: _buildPreview(l10n)),
            const SizedBox(height: 14),
            UploadSurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  UploadSectionLabel(
                    l10n.uploadVisibility,
                    help: _privacy == null ? l10n.tiktokPrivacyChoose : null,
                  ),
                  const SizedBox(height: 10),
                  KeyedSubtree(
                    key: const Key('tiktok-privacy'),
                    child: UploadChoiceChips<String>(
                      value: _privacy,
                      enabled: !_busy && creator != null,
                      options: [
                        for (final option in privacyOptions)
                          (option, _privacyLabel(l10n, option)),
                      ],
                      onChanged: (value) {
                        if (_disclose && _branded && value == _selfOnly) {
                          return;
                        }
                        setState(() {
                          _privacy = value;
                          if (_alsoYouTube) {
                            _youtubePrivacy =
                                CrossPostPrivacy.tikTokToYouTube(value);
                          }
                        });
                      },
                    ),
                  ),
                  if (_disclose && _branded && _privacy == _selfOnly)
                    _warning(l10n.tiktokBrandedNotPrivate),
                  if (_tooLong)
                    _warning(l10n.tiktokTooLong(creator!.maxDurationSeconds!)),
                ],
              ),
            ),
            const SizedBox(height: 14),
            UploadSurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  UploadSectionLabel(l10n.tiktokInteractionTitle),
                  const SizedBox(height: 4),
                  _interactionTile(
                    l10n.tiktokAllowComment,
                    _allowComment,
                    creator?.commentDisabled ?? false,
                    (v) => setState(() => _allowComment = v),
                    l10n,
                  ),
                  _interactionTile(
                    l10n.tiktokAllowDuet,
                    _allowDuet,
                    creator?.duetDisabled ?? false,
                    (v) => setState(() => _allowDuet = v),
                    l10n,
                  ),
                  _interactionTile(
                    l10n.tiktokAllowStitch,
                    _allowStitch,
                    creator?.stitchDisabled ?? false,
                    (v) => setState(() => _allowStitch = v),
                    l10n,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            UploadSurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  UploadToggleTile(
                    title: l10n.tiktokDisclose,
                    subtitle: l10n.tiktokDiscloseHelp,
                    value: _disclose,
                    enabled: !_busy,
                    onChanged: (value) => setState(() {
                      _disclose = value;
                      if (!value) {
                        _yourBrand = false;
                        _branded = false;
                      }
                    }),
                  ),
                  if (_disclose) ...[
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
                      subtitle: Text(
                        l10n.tiktokYourBrandHelp,
                        style: GoogleFonts.dmSans(
                          fontSize: 12,
                          color: AppTheme.muted,
                        ),
                      ),
                      value: _yourBrand,
                      onChanged: _busy
                          ? null
                          : (value) =>
                                setState(() => _yourBrand = value ?? false),
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
                      subtitle: Text(
                        l10n.tiktokBrandedContentHelp,
                        style: GoogleFonts.dmSans(
                          fontSize: 12,
                          color: AppTheme.muted,
                        ),
                      ),
                      value: _branded,
                      onChanged: _busy
                          ? null
                          : (value) =>
                                setState(() => _branded = value ?? false),
                    ),
                    if (_disclosureIncomplete)
                      _warning(l10n.tiktokDiscloseNeedOne),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),
            _buildConsent(l10n),
            const SizedBox(height: 14),
            UploadSurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  UploadCrossPostToggle(
                    title: l10n.crossPostAlsoYouTube,
                    value: _alsoYouTube,
                    enabled: !_busy,
                    onChanged: _setAlsoYouTube,
                  ),
                  if (_alsoYouTube) ...[
                    const SizedBox(height: 8),
                    _buildYouTubeCrossAccount(l10n),
                    if (_youtubeAccount != null) ...[
                      const SizedBox(height: 12),
                      UploadSectionLabel(l10n.uploadVisibility),
                      const SizedBox(height: 8),
                      UploadChoiceChips<String>(
                        value: _youtubePrivacy,
                        enabled: !_busy,
                        options: [
                          ('public', l10n.privacyPublic),
                          ('unlisted', l10n.privacyUnlisted),
                          ('private', l10n.privacyPrivate),
                        ],
                        onChanged: (value) =>
                            setState(() => _youtubePrivacy = value),
                      ),
                      const SizedBox(height: 12),
                      UploadSectionLabel(
                        l10n.uploadAudience,
                        help: l10n.uploadAudienceHelp,
                      ),
                      const SizedBox(height: 8),
                      UploadChoiceChips<bool>(
                        value: _youtubeMadeForKids,
                        enabled: !_busy,
                        options: [
                          (false, l10n.uploadAudienceNotForKids),
                          (true, l10n.uploadAudienceForKids),
                        ],
                        onChanged: (value) =>
                            setState(() => _youtubeMadeForKids = value),
                      ),
                      UploadToggleTile(
                        title: l10n.uploadPaidPromotion,
                        subtitle: l10n.uploadPaidPromotionHelp,
                        value: _youtubePaidPromotion,
                        enabled: !_busy,
                        onChanged: (v) =>
                            setState(() => _youtubePaidPromotion = v),
                      ),
                      UploadToggleTile(
                        title: l10n.uploadAlteredContent,
                        subtitle: l10n.uploadAlteredContentHelp,
                        value: _youtubeSyntheticMedia,
                        enabled: !_busy,
                        onChanged: (v) =>
                            setState(() => _youtubeSyntheticMedia = v),
                      ),
                    ] else if (!_youtubeAccountLoading)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          l10n.uploadAccountNone,
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
            const SizedBox(height: 16),
            KeyedSubtree(
              key: const Key('tiktok-post'),
              child: UploadGradientButton(
                label: _alsoYouTube
                    ? l10n.tiktokPostAndYouTube
                    : l10n.tiktokPost,
                onPressed: _canPost ? _submit : null,
                busy: _busy,
                busyProgress: _busy ? _overallBusyProgress : null,
                busyLabel: UploadBusyStatusLabel(_busyStatusText(l10n)),
              ),
            ),
            if (widget.onFinishInApp != null) ...[
              const SizedBox(height: 4),
              TextButton(
                onPressed: _busy
                    ? null
                    : () async {
                        Navigator.of(context).pop();
                        await widget.onFinishInApp!();
                      },
                child: Text(
                  l10n.tiktokFinishInApp,
                  style: GoogleFonts.dmSans(
                    color: AppTheme.muted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _warning(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        text,
        style: GoogleFonts.dmSans(
          color: const Color(0xFFFF6B8A),
          fontSize: 12,
          height: 1.35,
        ),
      ),
    );
  }

  Widget _interactionTile(
    String title,
    bool value,
    bool disabledByCreator,
    ValueChanged<bool> onChanged,
    AppLocalizations l10n,
  ) {
    return UploadToggleTile(
      title: title,
      subtitle: disabledByCreator ? l10n.tiktokInteractionOff : null,
      value: value && !disabledByCreator,
      enabled: !_busy && !disabledByCreator && _creator != null,
      onChanged: onChanged,
    );
  }

  Widget _buildConsent(AppLocalizations l10n) {
    final linkStyle = GoogleFonts.dmSans(
      color: AppTheme.accentCyan,
      decoration: TextDecoration.underline,
      fontSize: 12,
    );
    TextSpan link(String label, String url) => TextSpan(
      text: label,
      style: linkStyle,
      recognizer: TapGestureRecognizer()
        ..onTap = () =>
            launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
    );
    const marker = '\u0000';
    final parts = l10n.tiktokConsent(marker).split(marker);
    final policies = <InlineSpan>[
      if (_disclose && _branded) ...[
        link(l10n.tiktokBrandPolicy, _brandPolicyUrl),
        TextSpan(text: l10n.tiktokAnd),
      ],
      link(l10n.tiktokMusicPolicy, _musicPolicyUrl),
    ];
    return Text.rich(
      TextSpan(
        style: GoogleFonts.dmSans(
          color: AppTheme.muted,
          fontSize: 12,
          height: 1.4,
        ),
        children: [
          TextSpan(text: parts.first),
          ...policies,
          if (parts.length > 1) TextSpan(text: parts.last),
        ],
      ),
    );
  }

  Widget _buildYouTubeCrossAccount(AppLocalizations l10n) {
    final account = _youtubeAccount;
    return Row(
      children: [
        CircleAvatar(
          radius: 16,
          backgroundColor: AppTheme.surfaceElevated,
          foregroundImage: account?.photoUrl == null
              ? null
              : NetworkImage(account!.photoUrl!),
          child: const Icon(
            Icons.person_outline,
            size: 18,
            color: AppTheme.muted,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            account?.email ??
                (_youtubeAccountLoading ? '' : l10n.uploadAccountNone),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.dmSans(
              fontWeight: FontWeight.w700,
              color: AppTheme.ink,
            ),
          ),
        ),
        if (_youtubeAccountLoading)
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          TextButton(
            onPressed: _busy
                ? null
                : () => _connectYouTube(fresh: account != null),
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
    );
  }

  Widget _buildAccountCard(AppLocalizations l10n) {
    final creator = _creator;
    return UploadSurfaceCard(
      key: const Key('tiktok-account-card'),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: AppTheme.surfaceElevated,
            foregroundImage: creator == null || creator.avatarUrl.isEmpty
                ? null
                : NetworkImage(creator.avatarUrl),
            child: const Icon(
              Icons.person_outline,
              size: 20,
              color: AppTheme.muted,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.tiktokAccountTitle,
                  style: GoogleFonts.dmSans(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.muted,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 2),
                if (creator == null)
                  Text(
                    _accountLoading ? '' : l10n.uploadAccountNone,
                    style: GoogleFonts.dmSans(color: AppTheme.ink),
                  )
                else ...[
                  Text(
                    creator.nickname.isEmpty
                        ? '@${creator.username}'
                        : creator.nickname,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.dmSans(
                      fontWeight: FontWeight.w700,
                      color: AppTheme.ink,
                    ),
                  ),
                  if (creator.username.isNotEmpty)
                    Text(
                      '@${creator.username}',
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
              key: const Key('tiktok-account-change'),
              onPressed: _busy
                  ? null
                  : () => _connect(fresh: creator != null),
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
      ),
    );
  }

  Widget _buildPreview(AppLocalizations l10n) {
    final preview = _preview;
    final ready = preview != null && preview.value.isInitialized;
    final cover = _coverBytes;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 78,
          height: 138,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ColoredBox(
              color: AppTheme.surfaceElevated,
              child: ready
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        if (cover != null)
                          Image.memory(
                            cover,
                            key: ValueKey(_coverTimestampMs),
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
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
                          child: Material(
                            color: Colors.black.withValues(alpha: 0.55),
                            shape: const CircleBorder(),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: _busy ? null : _editCover,
                              child: const SizedBox(
                                width: 26,
                                height: 26,
                                child: Icon(
                                  Icons.edit,
                                  size: 15,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
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
                                  l10n.uploadThumbnail,
                                  style: GoogleFonts.dmSans(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  : const Center(
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: TextField(
            key: const Key('tiktok-caption'),
            controller: _captionController,
            enabled: !_busy,
            minLines: 3,
            maxLines: 6,
            maxLength: 2200,
            textInputAction: TextInputAction.newline,
            style: GoogleFonts.spaceGrotesk(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppTheme.ink,
              height: 1.25,
            ),
            decoration: InputDecoration(
              hintText: l10n.tiktokCaptionHint,
              hintStyle: GoogleFonts.spaceGrotesk(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: AppTheme.muted.withValues(alpha: 0.7),
              ),
              border: InputBorder.none,
              isCollapsed: true,
              counterStyle: GoogleFonts.dmSans(
                fontSize: 11,
                color: AppTheme.muted,
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _dismissKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// Same as YouTube upload — Done above the system keyboard.
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

  Widget _buildDone(AppLocalizations l10n, TikTokPublishStatus status) {
    final username = _creator?.username ?? '';
    final postId = status.postIds?.firstOrNull;
    final url = username.isEmpty
        ? 'https://www.tiktok.com/'
        : postId == null
        ? 'https://www.tiktok.com/@$username'
        : 'https://www.tiktok.com/@$username/video/$postId';
    return UploadAmbientScaffold(
      key: const Key('tiktok-upload-done'),
      automaticallyImplyLeading: false,
      title: l10n.tiktokUploadTitle,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
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
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
        children: [
          const Center(child: UploadCheckBadge()),
          const SizedBox(height: 18),
          Text(
            l10n.tiktokDoneTitle,
            textAlign: TextAlign.center,
            style: GoogleFonts.spaceGrotesk(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: AppTheme.ink,
            ),
          ),
          const SizedBox(height: 6),
          if (_privacy != null)
            Text(
              l10n.uploadDoneVisibility(_privacyLabel(l10n, _privacy!)),
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
          const SizedBox(height: 12),
          Text(
            l10n.tiktokDoneProcessing,
            textAlign: TextAlign.center,
            style: GoogleFonts.dmSans(color: AppTheme.muted, fontSize: 12),
          ),
          const SizedBox(height: 28),
          UploadGradientButton(
            label: l10n.tiktokOpen,
            onPressed: () => launchUrl(
              Uri.parse(url),
              mode: LaunchMode.externalApplication,
            ),
          ),
          if (_youtubeCrossOpenUrl != null) ...[
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () => launchUrl(
                Uri.parse(_youtubeCrossOpenUrl!),
                mode: LaunchMode.externalApplication,
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                foregroundColor: AppTheme.ink,
              ),
              child: Text(
                l10n.uploadDoneOpen,
                style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

enum _TikTokBusyPhase {
  idle,
  uploadingTikTok,
  processingTikTok,
  uploadingYouTube,
  finishingYouTube,
}
