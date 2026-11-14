import 'dart:io';

import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/services/analytics_service.dart';
import 'package:aveditor/services/tiktok_auth_service.dart';
import 'package:aveditor/services/tiktok_post_service.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

/// Direct Post to TikTok (Content Posting API), following TikTok's required
/// UX: creator shown, privacy chosen by the user with no default,
/// interactions off by default, commercial disclosure, consent text.
class TikTokUploadScreen extends StatefulWidget {
  const TikTokUploadScreen({
    super.key,
    required this.videoPath,
    this.onFinishInApp,
    this.auth,
    this.posts,
  });

  /// Exported video file to post.
  final String videoPath;

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
  double? _uploadProgress;
  bool _processing = false;
  TikTokPublishStatus? _done;

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
      if (mounted) setState(() {});
    } catch (error) {
      debugPrint('[TikTokUpload] 미리보기 실패: $error');
    }
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
      !(_disclose && _branded && _privacy == _selfOnly);

  Future<void> _submit() async {
    final session = _session;
    final privacy = _privacy;
    if (session == null || privacy == null || !_canPost) return;
    setState(() {
      _busy = true;
      _uploadProgress = 0;
      _processing = false;
    });
    await _preview?.pause();
    try {
      final info = TikTokPostInfo(
        title: _captionController.text.trim(),
        privacyLevel: privacy,
        allowComment: _allowComment,
        allowDuet: _allowDuet,
        allowStitch: _allowStitch,
        brandOrganic: _disclose && _yourBrand,
        brandedContent: _disclose && _branded,
      );
      final publishId = await _posts.publish(
        accessToken: session.accessToken,
        file: File(widget.videoPath),
        info: info,
        onProgress: (value) {
          if (mounted) setState(() => _uploadProgress = value);
        },
      );
      if (!mounted) return;
      setState(() => _processing = true);
      final status = await _posts.waitForPublish(
        session.accessToken,
        publishId,
      );
      if (status.state == TikTokPublishState.failed) {
        throw TikTokApiException('publish_failed', message: status.failReason);
      }
      AnalyticsService.instance.log('tiktok_post_completed', {
        'privacy': privacy,
      });
      if (!mounted) return;
      setState(() => _done = status);
    } catch (error, stack) {
      debugPrint('[TikTokUpload] 게시 실패: $error\n$stack');
      if (!mounted) return;
      setState(() => _busy = false);
      await _showError(error);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _uploadProgress = null;
          _processing = false;
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

    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.tiktokUploadTitle)),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            _buildAccountCard(l10n),
            const SizedBox(height: 16),
            if (creator == null && !_accountLoading)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  l10n.tiktokConnectHelp,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            _buildPreview(l10n),
            const SizedBox(height: 20),
            DropdownButtonFormField<String>(
              key: const Key('tiktok-privacy'),
              initialValue: _privacy,
              hint: Text(l10n.tiktokPrivacyChoose),
              decoration: InputDecoration(labelText: l10n.uploadVisibility),
              items: [
                for (final option in creator?.privacyOptions ?? const [])
                  DropdownMenuItem(
                    value: option,
                    enabled: !(_disclose && _branded && option == _selfOnly),
                    child: Text(_privacyLabel(l10n, option)),
                  ),
              ],
              onChanged: _busy || creator == null
                  ? null
                  : (value) => setState(() => _privacy = value),
            ),
            if (_disclose && _branded && _privacy == _selfOnly)
              _warning(l10n.tiktokBrandedNotPrivate),
            if (_tooLong)
              _warning(l10n.tiktokTooLong(creator!.maxDurationSeconds!)),
            const SizedBox(height: 16),
            Text(
              l10n.tiktokInteractionTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
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
            const Divider(height: 24),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.tiktokDisclose),
              subtitle: Text(l10n.tiktokDiscloseHelp),
              value: _disclose,
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
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
                title: Text(l10n.tiktokYourBrand),
                subtitle: Text(l10n.tiktokYourBrandHelp),
                value: _yourBrand,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _yourBrand = value ?? false),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(l10n.tiktokBrandedContent),
                subtitle: Text(l10n.tiktokBrandedContentHelp),
                value: _branded,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _branded = value ?? false),
              ),
              if (_disclosureIncomplete) _warning(l10n.tiktokDiscloseNeedOne),
            ],
            const SizedBox(height: 16),
            _buildConsent(l10n),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('tiktok-post'),
              onPressed: _canPost ? _submit : null,
              child: _busy
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          _processing
                              ? l10n.tiktokProcessing
                              : l10n.tiktokUploading(
                                  ((_uploadProgress ?? 0) * 100).round(),
                                ),
                        ),
                      ],
                    )
                  : Text(l10n.tiktokPost),
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
                child: Text(l10n.tiktokFinishInApp),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _warning(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        text,
        style: TextStyle(
          color: Theme.of(context).colorScheme.error,
          fontSize: 12,
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
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(title),
      subtitle: disabledByCreator ? Text(l10n.tiktokInteractionOff) : null,
      value: value && !disabledByCreator,
      onChanged: _busy || disabledByCreator || _creator == null
          ? null
          : onChanged,
    );
  }

  Widget _buildConsent(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final linkStyle = TextStyle(
      color: theme.colorScheme.primary,
      decoration: TextDecoration.underline,
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
        style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
        children: [
          TextSpan(text: parts.first),
          ...policies,
          if (parts.length > 1) TextSpan(text: parts.last),
        ],
      ),
    );
  }

  Widget _buildAccountCard(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final creator = _creator;
    return Material(
      key: const Key('tiktok-account-card'),
      color: AppTheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              foregroundImage: creator == null || creator.avatarUrl.isEmpty
                  ? null
                  : NetworkImage(creator.avatarUrl),
              child: Icon(
                Icons.person_outline,
                size: 20,
                color: theme.hintColor,
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
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  if (creator == null)
                    Text(
                      _accountLoading ? '' : l10n.uploadAccountNone,
                      style: theme.textTheme.bodyMedium,
                    )
                  else ...[
                    Text(
                      creator.nickname.isEmpty
                          ? '@${creator.username}'
                          : creator.nickname,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (creator.username.isNotEmpty)
                      Text(
                        '@${creator.username}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.hintColor,
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
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview(AppLocalizations l10n) {
    final preview = _preview;
    final ready = preview != null && preview.value.isInitialized;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: 78,
            height: 138,
            child: ColoredBox(
              color: AppTheme.surface,
              child: ready
                  ? FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: preview.value.size.width,
                        height: preview.value.size.height,
                        child: VideoPlayer(preview),
                      ),
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
            decoration: InputDecoration(
              hintText: l10n.tiktokCaptionHint,
              border: InputBorder.none,
              isCollapsed: true,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDone(AppLocalizations l10n, TikTokPublishStatus status) {
    final theme = Theme.of(context);
    final username = _creator?.username ?? '';
    final postId = status.postIds?.firstOrNull;
    final url = username.isEmpty
        ? 'https://www.tiktok.com/'
        : postId == null
        ? 'https://www.tiktok.com/@$username'
        : 'https://www.tiktok.com/@$username/video/$postId';
    return Scaffold(
      key: const Key('tiktok-upload-done'),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(l10n.tiktokUploadTitle),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.uploadDoneClose),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
        children: [
          Center(
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.check_rounded,
                size: 44,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            l10n.tiktokDoneTitle,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          if (_privacy != null)
            Text(
              l10n.uploadDoneVisibility(_privacyLabel(l10n, _privacy!)),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.hintColor,
              ),
            ),
          const SizedBox(height: 12),
          Text(
            l10n.tiktokDoneProcessing,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
          const SizedBox(height: 28),
          FilledButton.icon(
            onPressed: () =>
                launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
            icon: const Icon(Icons.open_in_new_rounded),
            label: Text(l10n.tiktokOpen),
          ),
        ],
      ),
    );
  }
}
