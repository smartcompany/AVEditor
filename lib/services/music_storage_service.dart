import 'dart:io';

import 'package:aveditor/models/project_music.dart';
import 'package:aveditor/models/royalty_free_track.dart';
import 'package:aveditor/services/music_catalog_service.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Copies or downloads music into a project folder.
class MusicStorageService {
  MusicStorageService({
    MusicCatalogService? catalog,
    http.Client? client,
  })  : catalog = catalog ?? MusicCatalogService(),
        _client = client;

  final MusicCatalogService catalog;
  final http.Client? _client;

  Future<ProjectMusic> importLocalFile({
    required String projectDir,
    required String pickedPath,
    required String title,
    String? artist,
    Duration? duration,
  }) async {
    final ext = p.extension(pickedPath);
    final fileName = 'music${ext.isEmpty ? '.mp3' : ext}';
    final dest = File(p.join(projectDir, fileName));
    await File(pickedPath).copy(dest.path);

    return ProjectMusic(
      title: title,
      artist: artist,
      fileName: fileName,
      fileDuration: duration,
      clipDuration: duration,
      source: MusicSource.local,
    );
  }

  Future<ProjectMusic> importCatalogTrack({
    required String projectDir,
    required RoyaltyFreeTrack track,
  }) async {
    if (!track.downloadAllowed) {
      throw StateError('music_download_not_allowed');
    }

    final uri = catalog.downloadUriFor(track);
    final response = await (_client ?? http.Client()).get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('music_download_failed:${response.statusCode}');
    }

    const fileName = 'music.mp3';
    final dest = File(p.join(projectDir, fileName));
    await dest.writeAsBytes(response.bodyBytes, flush: true);

    final fileDuration =
        track.duration > Duration.zero ? track.duration : null;

    return ProjectMusic(
      title: track.title,
      artist: track.artist,
      fileName: fileName,
      fileDuration: fileDuration,
      clipDuration: fileDuration,
      licenseUrl: track.licenseUrl,
      source: track.source,
      externalId: track.id,
    );
  }

  static String musicPath(String projectDir, ProjectMusic music) {
    return p.join(projectDir, music.fileName);
  }
}
