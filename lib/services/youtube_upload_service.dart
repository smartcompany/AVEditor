import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/services/youtube_errors.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Uploads an exported MP4 with YouTube Data API `videos.insert` (resumable).
class YouTubeUploadService {
  YouTubeUploadService({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  Future<String> uploadShort({
    required String filePath,
    required String accessToken,
    required String title,
    required String description,
    required String privacyStatus,
    required bool madeForKids,
    List<String> tags = const [],
    bool containsSyntheticMedia = false,
    bool paidPromotion = false,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw StateError('Exported video not found');
    }
    final length = await file.length();
    final parts = <String>['snippet', 'status'];
    final snippet = <String, Object>{
      'title': title,
      'description': description,
      'categoryId': '22',
      if (tags.isNotEmpty) 'tags': tags,
    };
    final status = <String, Object>{
      'privacyStatus': privacyStatus,
      'selfDeclaredMadeForKids': madeForKids,
      if (containsSyntheticMedia) 'containsSyntheticMedia': true,
    };
    final metadata = <String, Object>{'snippet': snippet, 'status': status};
    if (paidPromotion) {
      parts.add('paidProductPlacementDetails');
      metadata['paidProductPlacementDetails'] = {
        'hasPaidProductPlacement': true,
      };
    }
    debugPrint('[YouTubeUpload] 업로드 세션 요청 $length바이트');
    final start = await _client.post(
      Uri.parse(
        'https://www.googleapis.com/upload/youtube/v3/videos'
        '?uploadType=resumable&part=${parts.join(',')}',
      ),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json; charset=UTF-8',
        'X-Upload-Content-Length': '$length',
        'X-Upload-Content-Type': 'video/*',
      },
      body: jsonEncode(metadata),
    );
    if (start.statusCode != 200) {
      debugPrint('[YouTubeUpload] 세션 실패 ${start.statusCode} ${start.body}');
      throw YouTubeApiException.fromResponse(
        step: 'upload',
        statusCode: start.statusCode,
        body: start.body,
      );
    }
    final location = start.headers['location'];
    if (location == null || location.isEmpty) {
      debugPrint('[YouTubeUpload] 세션 응답에 업로드 주소 없음');
      throw StateError('YouTube upload location missing');
    }
    debugPrint('[YouTubeUpload] 업로드 세션 준비됨');

    final request = http.StreamedRequest('PUT', Uri.parse(location));
    request.headers.addAll({
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'video/*',
    });
    request.contentLength = length;
    final responseFuture = _client.send(request);
    var sent = 0;
    var lastBucket = -1;
    await for (final chunk in file.openRead()) {
      request.sink.add(chunk);
      sent += chunk.length;
      final percent = length == 0 ? 100 : (sent * 100 ~/ length);
      final bucket = percent ~/ 10;
      if (bucket == lastBucket) continue;
      lastBucket = bucket;
      debugPrint('[YouTubeUpload] 전송 $percent% ($sent/$length)');
    }
    unawaited(request.sink.close());
    final put = await responseFuture;
    final body = await put.stream.bytesToString();
    if (put.statusCode != 200 && put.statusCode != 201) {
      debugPrint('[YouTubeUpload] 전송 실패 ${put.statusCode} $body');
      throw YouTubeApiException.fromResponse(
        step: 'upload',
        statusCode: put.statusCode,
        body: body,
      );
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('YouTube upload response was not an object');
    }
    final id = decoded['id'];
    if (id is! String || id.isEmpty) {
      throw StateError('YouTube video id missing');
    }
    return id;
  }

  Future<String> uploadProject({
    required VideoProject project,
    required String exportedPath,
    required String accessToken,
    required String title,
    required String description,
    required String privacyStatus,
    required bool madeForKids,
    List<String> tags = const [],
    bool containsSyntheticMedia = false,
    bool paidPromotion = false,
  }) {
    return uploadShort(
      filePath: exportedPath,
      accessToken: accessToken,
      title: title,
      description: description,
      privacyStatus: privacyStatus,
      madeForKids: madeForKids,
      tags: tags,
      containsSyntheticMedia: containsSyntheticMedia,
      paidPromotion: paidPromotion,
    );
  }

  Future<void> setThumbnail({
    required String accessToken,
    required String videoId,
    required String imagePath,
  }) async {
    final file = File(imagePath);
    final bytes = await file.readAsBytes();
    final lower = imagePath.toLowerCase();
    final type = lower.endsWith('.png') ? 'image/png' : 'image/jpeg';
    debugPrint('[YouTubeUpload] 썸네일 설정 ${bytes.length}바이트');
    final response = await _client.post(
      Uri.parse(
        'https://www.googleapis.com/upload/youtube/v3/thumbnails/set'
        '?videoId=$videoId&uploadType=media',
      ),
      headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': type},
      body: bytes,
    );
    if (response.statusCode != 200) {
      debugPrint(
        '[YouTubeUpload] 썸네일 실패 ${response.statusCode} ${response.body}',
      );
      throw YouTubeApiException.fromResponse(
        step: 'thumbnail',
        statusCode: response.statusCode,
        body: response.body,
      );
    }
    debugPrint('[YouTubeUpload] 썸네일 완료');
  }

}


/// Accepts a bare id or a watch, shorts, embed, or youtu.be link.
String? youtubeVideoId(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(text)) return text;
  return RegExp(
    r'(?:youtu\.be/|youtube\.com/(?:watch\?(?:.*&)?v=|shorts/|embed/|live/))([A-Za-z0-9_-]{11})',
  ).firstMatch(text)?.group(1);
}

/// Splits comma-separated tags and keeps YouTube's 500-character budget.
List<String> youtubeTags(String raw) {
  final tags = <String>[];
  var budget = 500;
  for (final part in raw.split(RegExp(r'[,\n]'))) {
    final tag = part.trim();
    if (tag.isEmpty) continue;
    final cost = tag.contains(' ') ? tag.length + 2 : tag.length;
    final separator = tags.isEmpty ? 0 : 1;
    if (separator + cost > budget) break;
    budget -= separator + cost;
    tags.add(tag);
  }
  return tags;
}
