import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aveditor/models/video_project.dart';
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
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw StateError('Exported video not found');
    }
    final length = await file.length();
    debugPrint('[YouTubeUpload] 업로드 세션 요청 $length바이트');
    final start = await _client.post(
      Uri.parse(
        'https://www.googleapis.com/upload/youtube/v3/videos'
        '?uploadType=resumable&part=snippet,status',
      ),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json; charset=UTF-8',
        'X-Upload-Content-Length': '$length',
        'X-Upload-Content-Type': 'video/*',
      },
      body: jsonEncode({
        'snippet': {
          'title': title,
          'description': description,
          'categoryId': '22',
        },
        'status': {
          'privacyStatus': privacyStatus,
          'selfDeclaredMadeForKids': madeForKids,
        },
      }),
    );
    if (start.statusCode != 200) {
      debugPrint('[YouTubeUpload] 세션 실패 ${start.statusCode} ${start.body}');
      throw StateError(
        'YouTube upload did not start (${start.statusCode}) ${start.body}',
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
      throw StateError('YouTube upload failed (${put.statusCode}) $body');
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
  }) {
    return uploadShort(
      filePath: exportedPath,
      accessToken: accessToken,
      title: title,
      description: description,
      privacyStatus: privacyStatus,
      madeForKids: madeForKids,
    );
  }

  Future<List<YouTubePlaylist>> listPlaylists(String accessToken) async {
    final playlists = <YouTubePlaylist>[];
    String? pageToken;
    for (var page = 0; page < 4; page++) {
      final response = await _client.get(
        Uri.https('www.googleapis.com', '/youtube/v3/playlists', {
          'part': 'snippet',
          'mine': 'true',
          'maxResults': '50',
          'pageToken': ?pageToken,
        }),
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      if (response.statusCode != 200) {
        debugPrint(
          '[YouTubeUpload] 재생목록 실패 ${response.statusCode} ${response.body}',
        );
        throw StateError(
          'YouTube playlists failed (${response.statusCode}) ${response.body}',
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) break;
      final items = decoded['items'];
      if (items is List) {
        for (final item in items) {
          if (item is! Map) continue;
          final id = item['id'];
          final snippet = item['snippet'];
          final title = snippet is Map ? snippet['title'] : null;
          if (id is String && title is String && title.isNotEmpty) {
            playlists.add(YouTubePlaylist(id: id, title: title));
          }
        }
      }
      final next = decoded['nextPageToken'];
      if (next is! String || next.isEmpty) break;
      pageToken = next;
    }
    debugPrint('[YouTubeUpload] 재생목록 ${playlists.length}개');
    return playlists;
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
      throw StateError(
        'YouTube thumbnail failed (${response.statusCode}) ${response.body}',
      );
    }
    debugPrint('[YouTubeUpload] 썸네일 완료');
  }

  Future<void> addToPlaylist({
    required String accessToken,
    required String videoId,
    required String playlistId,
  }) async {
    debugPrint('[YouTubeUpload] 재생목록 추가 playlistId=$playlistId');
    final response = await _client.post(
      Uri.parse(
        'https://www.googleapis.com/youtube/v3/playlistItems?part=snippet',
      ),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json; charset=UTF-8',
      },
      body: jsonEncode({
        'snippet': {
          'playlistId': playlistId,
          'resourceId': {'kind': 'youtube#video', 'videoId': videoId},
        },
      }),
    );
    if (response.statusCode != 200) {
      debugPrint(
        '[YouTubeUpload] 재생목록 추가 실패 ${response.statusCode} ${response.body}',
      );
      throw StateError(
        'YouTube playlist failed (${response.statusCode}) ${response.body}',
      );
    }
    debugPrint('[YouTubeUpload] 재생목록 추가 완료');
  }

  Future<void> setAgeRestricted({
    required String accessToken,
    required String videoId,
  }) async {
    debugPrint('[YouTubeUpload] 연령 제한 설정');
    final response = await _client.put(
      Uri.parse(
        'https://www.googleapis.com/youtube/v3/videos?part=contentDetails',
      ),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json; charset=UTF-8',
      },
      body: jsonEncode({
        'id': videoId,
        'contentDetails': {
          'contentRating': {'ytRating': 'ytAgeRestricted'},
        },
      }),
    );
    if (response.statusCode != 200) {
      debugPrint(
        '[YouTubeUpload] 연령 제한 실패 ${response.statusCode} ${response.body}',
      );
      throw StateError(
        'YouTube age restriction failed (${response.statusCode}) ${response.body}',
      );
    }
    debugPrint('[YouTubeUpload] 연령 제한 완료');
  }
}

class YouTubePlaylist {
  const YouTubePlaylist({required this.id, required this.title});

  final String id;
  final String title;
}
