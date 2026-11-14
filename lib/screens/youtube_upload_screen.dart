import 'dart:io';

import 'package:aveditor/services/analytics_service.dart';
import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/screens/thumbnail_editor_screen.dart';
import 'package:aveditor/services/app_settings_service.dart';
import 'package:aveditor/services/export_service.dart';
import 'package:aveditor/services/export_share_service.dart';
import 'package:aveditor/services/youtube_auth_service.dart';
import 'package:aveditor/services/youtube_errors.dart';
import 'package:aveditor/services/youtube_upload_service.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  final _locationController = TextEditingController();
  final _relatedController = TextEditingController();
  final _tagsController = TextEditingController();
  String _privacy = 'public';
  bool _madeForKids = false;
  bool _ageRestricted = false;
  bool _paidPromotion = false;
  bool _syntheticMedia = false;
  bool _busy = false;
  bool _moreOpen = false;
  String? _thumbnailPath;
  String? _playlistId;
  List<YouTubePlaylist> _playlists = const [];
  bool _playlistsLoading = false;
  String? _playlistsError;
  GoogleSignInAccount? _account;
  bool _accountLoading = true;

  /// Set once the video is on YouTube; the screen then shows the result.
  String? _uploadedId;

  /// Settings that could not be applied after the upload, if any.
  String? _partialSteps;

  VideoPlayerController? _preview;
  var _previewFailed = false;

  final _export = ExportService();
  final _upload = YouTubeUploadService();
  final _auth = YouTubeAuthService();
  final _settings = const AppSettingsService();

  @override
  void initState() {
    super.initState();
    _openPreview();
    _restoreAccount();
  }

  Future<void> _restoreAccount() async {
    final account = await _auth.currentAccount();
    if (!mounted) return;
    setState(() {
      _account = account;
      _accountLoading = false;
    });
  }

  /// Connects an account, or replaces the current one. Playlists belong to
  /// the account, so they are reset.
  Future<bool> _changeAccount() async {
    setState(() => _accountLoading = true);
    try {
      final account = _account == null
          ? await _connectAccount()
          : await _auth.switchAccount();
      if (!mounted) return false;
      setState(() {
        _account = account;
        _playlists = const [];
        _playlistId = null;
        _playlistsError = null;
      });
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
    _locationController.dispose();
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

  Future<void> _loadPlaylists() async {
    setState(() {
      _playlistsLoading = true;
      _playlistsError = null;
    });
    try {
      if (!await _auth.isSignedIn) {
        await _auth.signIn();
        final account = await _auth.currentAccount();
        if (mounted) setState(() => _account = account);
      }
      await _auth.ensureAccountScope();
      final token = await _auth.accessToken();
      final playlists = await _upload.listPlaylists(token);
      if (!mounted) return;
      setState(() => _playlists = playlists);
    } catch (error, stack) {
      debugPrint('[YouTubeUpload] 재생목록 실패: $error\n$stack');
      if (!mounted) return;
      setState(() => _playlistsError = context.l10n.uploadPlaylistFailed);
    } finally {
      if (mounted) setState(() => _playlistsLoading = false);
    }
  }

  Future<void> _pickPlaylist() async {
    if (_playlists.isEmpty && !_playlistsLoading) {
      await _loadPlaylists();
      if (!mounted || _playlistsError != null) return;
    }
    if (!mounted) return;
    final l10n = context.l10n;
    final selected = await showModalBottomSheet<String?>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.6,
            ),
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  title: Text(l10n.uploadPlaylistNone),
                  trailing: _playlistId == null
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.pop(context, ''),
                ),
                for (final playlist in _playlists)
                  ListTile(
                    title: Text(playlist.title),
                    trailing: _playlistId == playlist.id
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () => Navigator.pop(context, playlist.id),
                  ),
                if (_playlists.isEmpty)
                  ListTile(title: Text(l10n.uploadPlaylistEmpty)),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted || selected == null) return;
    setState(() => _playlistId = selected.isEmpty ? null : selected);
  }

  String _playlistLabel(AppLocalizations l10n) {
    if (_playlistId == null) return l10n.uploadPlaylistNone;
    for (final playlist in _playlists) {
      if (playlist.id == _playlistId) return playlist.title;
    }
    return l10n.uploadPlaylistNone;
  }

  Future<void> _submit() async {
    final l10n = context.l10n;
    var description = _descriptionController.text.trim();
    final title = _titleFromCaption(description);
    if (title.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.uploadTitleHint)));
      return;
    }
    final relatedRaw = _relatedController.text.trim();
    final relatedId = youtubeVideoId(relatedRaw);
    if (relatedRaw.isNotEmpty && relatedId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.uploadRelatedVideoInvalid)));
      return;
    }
    final tags = youtubeTags(_tagsController.text);
    if (relatedId != null) {
      final link = 'https://www.youtube.com/watch?v=$relatedId';
      if (!description.contains(link)) {
        description = description.isEmpty ? link : '$description\n$link';
      }
    }

    setState(() => _busy = true);
    await _preview?.pause();
    debugPrint(
      '[YouTubeUpload] 시작 title="$title" '
      'privacy=$_privacy kids=$_madeForKids ageRestricted=$_ageRestricted '
      'paid=$_paidPromotion synthetic=$_syntheticMedia '
      'tags=${tags.length} location="${_locationController.text.trim()}" '
      'related=${relatedId ?? "none"} '
      'playlist=${_playlistId ?? "none"} '
      'thumbnail=${_thumbnailPath == null ? "auto" : "custom"}',
    );
    String? videoId;
    try {
      ({double latitude, double longitude})? place;
      final location = _locationController.text.trim();
      if (location.isNotEmpty) {
        place = await _upload.lookupPlace(location);
        if (!mounted) return;
        if (place == null) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l10n.uploadLocationNotFound)));
          return;
        }
      }
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
      if (_playlistId != null || _ageRestricted || place != null) {
        await _auth.ensureAccountScope();
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
        var lastExportBucket = -1;
        path = await _export.exportForPreset(
          widget.project,
          quality: quality,
          onProgress: (progress) {
            final percent = (progress.clamp(0.0, 1.0) * 100).round();
            final bucket = percent ~/ 10;
            if (bucket == lastExportBucket) return;
            lastExportBucket = bucket;
            debugPrint('[YouTubeUpload] 내보내기 $percent%');
          },
        );
        debugPrint('[YouTubeUpload] 내보내기 완료 path=$path');
      }
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
      );
      debugPrint('[YouTubeUpload] 업로드 완료 videoId=$videoId');
      AnalyticsService.instance.log('youtube_upload_completed');
      final followUp = await _applyDetails(
        token: token,
        videoId: videoId,
        place: place,
      );
      if (!mounted) return;
      await _preview?.pause();
      setState(() {
        _uploadedId = videoId;
        _partialSteps = followUp;
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
      if (mounted) setState(() => _busy = false);
    }
  }

  String _stepNames(AppLocalizations l10n, Object error) {
    final step = error is YouTubeApiException ? error.step : '';
    return switch (step) {
      'thumbnail' => l10n.uploadStepThumbnail,
      'playlist' => l10n.uploadStepPlaylist,
      'ageRestriction' => l10n.uploadStepAgeRestriction,
      'location' => l10n.uploadStepLocation,
      _ => [
        l10n.uploadStepThumbnail,
        l10n.uploadStepPlaylist,
        l10n.uploadStepAgeRestriction,
        l10n.uploadStepLocation,
      ].join(', '),
    };
  }

  /// Applies the settings that need extra calls after the upload. Returns
  /// the names of the settings that failed, or null when all succeeded.
  Future<String?> _applyDetails({
    required String token,
    required String videoId,
    ({double latitude, double longitude})? place,
  }) async {
    final l10n = context.l10n;
    final errors = <String>[];
    final thumbnail = _thumbnailPath;
    if (thumbnail != null) {
      try {
        await _upload.setThumbnail(
          accessToken: token,
          videoId: videoId,
          imagePath: thumbnail,
        );
      } catch (error) {
        debugPrint('[YouTubeUpload] 후속 단계 실패: $error');
        errors.add(l10n.uploadStepThumbnail);
      }
    }
    final playlistId = _playlistId;
    if (playlistId != null) {
      try {
        await _upload.addToPlaylist(
          accessToken: token,
          videoId: videoId,
          playlistId: playlistId,
        );
      } catch (error) {
        debugPrint('[YouTubeUpload] 후속 단계 실패: $error');
        errors.add(l10n.uploadStepPlaylist);
      }
    }
    if (_ageRestricted && !_madeForKids) {
      try {
        await _upload.setAgeRestricted(accessToken: token, videoId: videoId);
      } catch (error) {
        debugPrint('[YouTubeUpload] 후속 단계 실패: $error');
        errors.add(l10n.uploadStepAgeRestriction);
      }
    }
    if (place != null) {
      try {
        await _upload.setRecordingLocation(
          accessToken: token,
          videoId: videoId,
          latitude: place.latitude,
          longitude: place.longitude,
        );
      } catch (error) {
        debugPrint('[YouTubeUpload] 후속 단계 실패: $error');
        errors.add(l10n.uploadStepLocation);
      }
    }
    if (errors.isEmpty) return null;
    return errors.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final preview = _preview;

    final uploadedId = _uploadedId;
    if (uploadedId != null) return _buildDone(l10n, uploadedId);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.uploadShorts)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          _buildAccountCard(l10n),
          const SizedBox(height: 16),
          _buildPreview(l10n, preview),
          const SizedBox(height: 20),
          DropdownButtonFormField<String>(
            initialValue: _privacy,
            decoration: InputDecoration(labelText: l10n.uploadVisibility),
            items: [
              DropdownMenuItem(
                value: 'public',
                child: Text(l10n.privacyPublic),
              ),
              DropdownMenuItem(
                value: 'unlisted',
                child: Text(l10n.privacyUnlisted),
              ),
              DropdownMenuItem(
                value: 'private',
                child: Text(l10n.privacyPrivate),
              ),
            ],
            onChanged: _busy
                ? null
                : (value) {
                    if (value != null) setState(() => _privacy = value);
                  },
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.uploadPlaylist),
            subtitle: Text(_playlistsError ?? _playlistLabel(l10n)),
            trailing: _playlistsLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
            onTap: _busy ? null : _pickPlaylist,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.uploadAudience,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            l10n.uploadAudienceHelp,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: false,
                label: Text(
                  l10n.uploadAudienceNotForKids,
                  textAlign: TextAlign.center,
                ),
              ),
              ButtonSegment(
                value: true,
                label: Text(
                  l10n.uploadAudienceForKids,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
            selected: {_madeForKids},
            onSelectionChanged: _busy
                ? null
                : (selection) {
                    setState(() {
                      _madeForKids = selection.first;
                      if (_madeForKids) _ageRestricted = false;
                    });
                  },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.uploadAgeRestriction),
            subtitle: Text(l10n.uploadAgeRestrictionHelp),
            value: _ageRestricted && !_madeForKids,
            onChanged: _busy || _madeForKids
                ? null
                : (value) => setState(() => _ageRestricted = value),
          ),
          const SizedBox(height: 8),
          if (_moreOpen) ...[
            TextField(
              controller: _locationController,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: l10n.uploadLocation,
                hintText: l10n.uploadLocationHint,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _relatedController,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: l10n.uploadRelatedVideo,
                hintText: l10n.uploadRelatedVideoHint,
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.uploadPaidPromotion),
              subtitle: Text(l10n.uploadPaidPromotionHelp),
              value: _paidPromotion,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _paidPromotion = value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.uploadAlteredContent),
              subtitle: Text(l10n.uploadAlteredContentHelp),
              value: _syntheticMedia,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _syntheticMedia = value),
            ),
            TextField(
              controller: _tagsController,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: l10n.uploadTags,
                hintText: l10n.uploadTagsHint,
              ),
            ),
            const SizedBox(height: 8),
          ],
          SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              onPressed: _busy
                  ? null
                  : () => setState(() => _moreOpen = !_moreOpen),
              icon: Icon(_moreOpen ? Icons.expand_less : Icons.expand_more),
              label: Text(
                _moreOpen ? l10n.uploadFewerDetails : l10n.uploadMoreDetails,
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.uploadShorts),
          ),
        ],
      ),
    );
  }

  String _privacyLabel(AppLocalizations l10n) {
    return switch (_privacy) {
      'private' => l10n.privacyPrivate,
      'unlisted' => l10n.privacyUnlisted,
      _ => l10n.privacyPublic,
    };
  }

  /// Result after a successful upload: stays on screen with the Shorts link
  /// instead of silently going back.
  Widget _buildDone(AppLocalizations l10n, String videoId) {
    final theme = Theme.of(context);
    final link = 'https://youtube.com/shorts/$videoId';
    final partial = _partialSteps;
    final thumbnail = _thumbnailPath;
    final preview = _preview;
    void close() => Navigator.of(context).pop();

    return Scaffold(
      key: const Key('youtube-upload-done'),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(l10n.uploadShorts),
        actions: [
          TextButton(onPressed: close, child: Text(l10n.uploadDoneClose)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
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
            l10n.uploadDoneTitle,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.uploadDoneVisibility(_privacyLabel(l10n)),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
          ),
          const SizedBox(height: 24),
          Material(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _copyLink(l10n, link),
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
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            link,
                            key: const Key('youtube-upload-link'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.copy_rounded, size: 18, color: theme.hintColor),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            l10n.uploadDoneProcessing,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
          if (partial != null) ...[
            const SizedBox(height: 12),
            DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.info_outline,
                      size: 18,
                      color: Colors.amber,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.uploadPartialDone(partial),
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 28),
          FilledButton.icon(
            onPressed: () => launchUrl(
              Uri.parse(link),
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(l10n.uploadDoneOpen),
          ),
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
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l10n.uploadDoneCopied)));
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
    return Material(
      key: const Key('youtube-account-card'),
      color: AppTheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
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
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  if (account == null)
                    Text(
                      _accountLoading ? '' : l10n.uploadAccountNone,
                      style: theme.textTheme.bodyMedium,
                    )
                  else ...[
                    Text(
                      name == null || name.isEmpty ? account.email : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (name != null && name.isNotEmpty)
                      Text(
                        account.email,
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
                key: const Key('youtube-account-change'),
                onPressed: _busy ? null : _changeAccount,
                child: Text(
                  account == null
                      ? l10n.uploadAccountConnect
                      : l10n.uploadAccountSwitch,
                ),
              ),
          ],
        ),
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
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
            decoration: InputDecoration(
              hintText: l10n.uploadShortsCaption,
              hintStyle: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w500,
                color: Theme.of(context).hintColor,
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
                      Image.file(File(_thumbnailPath!), fit: BoxFit.cover)
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
