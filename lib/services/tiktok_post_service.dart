import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// A Content Posting API error (`error.code` other than `ok`), or an HTTP
/// failure. [code] is TikTok's error code; the UI maps it to a message.
class TikTokApiException implements Exception {
  const TikTokApiException(this.code, {this.message = '', this.logId = ''});

  factory TikTokApiException.fromBody(int status, String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final error = json['error'];
      if (error is Map) {
        return TikTokApiException(
          '${error['code'] ?? 'http_$status'}',
          message: '${error['message'] ?? ''}',
          logId: '${error['log_id'] ?? ''}',
        );
      }
    } catch (_) {}
    return TikTokApiException('http_$status');
  }

  final String code;
  final String message;
  final String logId;

  @override
  String toString() => 'TikTokApiException($code $message $logId)';
}

/// What `creator_info/query` says this account may do. Required by TikTok's
/// Direct Post UX rules: privacy options come from here (no default), and
/// interactions the creator turned off must stay off.
class TikTokCreatorInfo {
  const TikTokCreatorInfo({
    required this.nickname,
    required this.username,
    required this.avatarUrl,
    required this.privacyOptions,
    required this.commentDisabled,
    required this.duetDisabled,
    required this.stitchDisabled,
    required this.maxDurationSeconds,
  });

  factory TikTokCreatorInfo.fromJson(Map<String, dynamic> data) {
    return TikTokCreatorInfo(
      nickname: '${data['creator_nickname'] ?? ''}',
      username: '${data['creator_username'] ?? ''}',
      avatarUrl: '${data['creator_avatar_url'] ?? ''}',
      privacyOptions: [
        for (final option in (data['privacy_level_options'] as List? ?? []))
          '$option',
      ],
      commentDisabled: data['comment_disabled'] == true,
      duetDisabled: data['duet_disabled'] == true,
      stitchDisabled: data['stitch_disabled'] == true,
      maxDurationSeconds: (data['max_video_post_duration_sec'] as num?)
          ?.toInt(),
    );
  }

  final String nickname;
  final String username;
  final String avatarUrl;

  /// PUBLIC_TO_EVERYONE, MUTUAL_FOLLOW_FRIENDS, FOLLOWER_OF_CREATOR, SELF_ONLY.
  final List<String> privacyOptions;
  final bool commentDisabled;
  final bool duetDisabled;
  final bool stitchDisabled;
  final int? maxDurationSeconds;
}

class TikTokPostInfo {
  const TikTokPostInfo({
    required this.title,
    required this.privacyLevel,
    required this.allowComment,
    required this.allowDuet,
    required this.allowStitch,
    this.coverTimestampMs = 0,
    this.brandOrganic = false,
    this.brandedContent = false,
  });

  final String title;
  final String privacyLevel;
  final bool allowComment;
  final bool allowDuet;
  final bool allowStitch;
  final int coverTimestampMs;

  /// "Your brand" — labelled Promotional content.
  final bool brandOrganic;

  /// "Branded content" — labelled Paid partnership; cannot be private.
  final bool brandedContent;

  Map<String, dynamic> toJson() => {
    'title': title,
    'privacy_level': privacyLevel,
    'disable_comment': !allowComment,
    'disable_duet': !allowDuet,
    'disable_stitch': !allowStitch,
    'video_cover_timestamp_ms': coverTimestampMs,
    'brand_organic_toggle': brandOrganic,
    'brand_content_toggle': brandedContent,
  };
}

/// Chunk layout for FILE_UPLOAD: files up to 64 MB go in one chunk; larger
/// files use 10 MB chunks with the remainder folded into the last one
/// (TikTok allows 5–64 MB chunks, the last up to 128 MB).
class TikTokChunkPlan {
  const TikTokChunkPlan(this.videoSize, this.chunkSize, this.chunkCount);

  factory TikTokChunkPlan.forSize(int size) {
    const single = 64 * 1024 * 1024;
    const chunk = 10 * 1024 * 1024;
    if (size <= single) return TikTokChunkPlan(size, size, 1);
    return TikTokChunkPlan(size, chunk, size ~/ chunk);
  }

  final int videoSize;
  final int chunkSize;
  final int chunkCount;

  /// Inclusive byte range of chunk [index].
  (int start, int end) range(int index) {
    final start = index * chunkSize;
    final end = index == chunkCount - 1 ? videoSize - 1 : start + chunkSize - 1;
    return (start, end);
  }
}

enum TikTokPublishState { processing, inbox, complete, failed }

class TikTokPublishStatus {
  const TikTokPublishStatus(this.state, {this.failReason = '', this.postIds});

  final TikTokPublishState state;
  final String failReason;
  final List<String>? postIds;
}

/// Content Posting API (Direct Post, FILE_UPLOAD) with the user's token.
class TikTokPostService {
  TikTokPostService({http.Client? client}) : _client = client ?? http.Client();

  static const _base = 'https://open.tiktokapis.com/v2/post/publish';

  final http.Client _client;

  Future<TikTokCreatorInfo> creatorInfo(String accessToken) async {
    final data = await _post(
      accessToken,
      '$_base/creator_info/query/',
      const {},
    );
    return TikTokCreatorInfo.fromJson(data);
  }

  /// Uploads [file] and starts publishing. Returns the publish id.
  Future<String> publish({
    required String accessToken,
    required File file,
    required TikTokPostInfo info,
    void Function(double progress)? onProgress,
  }) async {
    final size = await file.length();
    final plan = TikTokChunkPlan.forSize(size);
    final data = await _post(accessToken, '$_base/video/init/', {
      'post_info': info.toJson(),
      'source_info': {
        'source': 'FILE_UPLOAD',
        'video_size': plan.videoSize,
        'chunk_size': plan.chunkSize,
        'total_chunk_count': plan.chunkCount,
      },
    });
    final publishId = '${data['publish_id'] ?? ''}';
    final uploadUrl = '${data['upload_url'] ?? ''}';
    if (publishId.isEmpty || uploadUrl.isEmpty) {
      throw const TikTokApiException('invalid_init_response');
    }
    var sent = 0;
    for (var i = 0; i < plan.chunkCount; i++) {
      final (start, end) = plan.range(i);
      await _uploadChunk(
        uploadUrl: uploadUrl,
        file: file,
        start: start,
        end: end,
        total: plan.videoSize,
        onBytes: (bytes) {
          sent += bytes;
          onProgress?.call(sent / plan.videoSize);
        },
      );
    }
    return publishId;
  }

  /// No bytes accepted for this long ends the upload as a network error
  /// instead of leaving the user on a frozen percentage.
  static const _stallTimeout = Duration(seconds: 60);

  /// Streams one chunk so progress follows what the socket has taken
  /// (the HTTP client pauses the file stream when the network is busy).
  Future<void> _uploadChunk({
    required String uploadUrl,
    required File file,
    required int start,
    required int end,
    required int total,
    required void Function(int bytes) onBytes,
  }) async {
    final request = http.StreamedRequest('PUT', Uri.parse(uploadUrl))
      ..headers['Content-Type'] = 'video/mp4'
      ..headers['Content-Range'] = 'bytes $start-$end/$total'
      ..contentLength = end - start + 1;
    Timer? stall;
    final failed = Completer<Never>();
    void armStall() {
      stall?.cancel();
      stall = Timer(_stallTimeout, () {
        if (!failed.isCompleted) {
          failed.completeError(const SocketException('upload stalled'));
        }
      });
    }

    armStall();
    final pump = file
        .openRead(start, end + 1)
        .map((bytes) {
          armStall();
          onBytes(bytes.length);
          return bytes;
        })
        .pipe(request.sink);
    // Keep a failed/abandoned file stream from surfacing as an uncaught error.
    unawaited(pump.then((_) {}, onError: (_) {}));
    try {
      final response = await Future.any([_client.send(request), failed.future]);
      await pump;
      final body = await response.stream.bytesToString();
      if (response.statusCode != 200 &&
          response.statusCode != 201 &&
          response.statusCode != 206) {
        throw TikTokApiException(
          'upload_failed_${response.statusCode}',
          message: body.length > 200 ? body.substring(0, 200) : body,
        );
      }
    } finally {
      stall?.cancel();
    }
  }

  Future<TikTokPublishStatus> status(
    String accessToken,
    String publishId,
  ) async {
    final data = await _post(accessToken, '$_base/status/fetch/', {
      'publish_id': publishId,
    });
    final state = switch ('${data['status']}') {
      'PUBLISH_COMPLETE' => TikTokPublishState.complete,
      'SEND_TO_USER_INBOX' => TikTokPublishState.inbox,
      'FAILED' => TikTokPublishState.failed,
      _ => TikTokPublishState.processing,
    };
    final ids = data['publicaly_available_post_id'];
    return TikTokPublishStatus(
      state,
      failReason: '${data['fail_reason'] ?? ''}',
      postIds: ids is List ? [for (final id in ids) '$id'] : null,
    );
  }

  /// Polls until TikTok finishes processing or [timeout] passes (then
  /// reports processing; the post usually still goes up).
  Future<TikTokPublishStatus> waitForPublish(
    String accessToken,
    String publishId, {
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final current = await status(accessToken, publishId);
      if (current.state != TikTokPublishState.processing ||
          DateTime.now().isAfter(deadline)) {
        return current;
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  }

  Future<Map<String, dynamic>> _post(
    String accessToken,
    String url,
    Map<String, dynamic> body,
  ) async {
    final res = await _client.post(
      Uri.parse(url),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json; charset=UTF-8',
      },
      body: jsonEncode(body),
    );
    final json = () {
      try {
        return jsonDecode(res.body) as Map<String, dynamic>;
      } catch (_) {
        return <String, dynamic>{};
      }
    }();
    final error = json['error'];
    final code = error is Map ? '${error['code']}' : null;
    if (res.statusCode != 200 || (code != null && code != 'ok')) {
      throw TikTokApiException.fromBody(res.statusCode, res.body);
    }
    final data = json['data'];
    return data is Map<String, dynamic> ? data : <String, dynamic>{};
  }
}
