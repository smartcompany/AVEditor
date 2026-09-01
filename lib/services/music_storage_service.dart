import 'dart:io';

import 'package:aveditor/models/project_music.dart';
import 'package:aveditor/models/royalty_free_track.dart';
import 'package:aveditor/services/jamendo_music_service.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Copies or downloads music into a project folder.
class MusicStorageService {
  const MusicStorageService({
    this.jamendo = const JamendoMusicService(),
    http.Client? client,
  }) : _client = client;

  final JamendoMusicService jamendo;
  final http.Client? _client;

  Future<ProjectMusic> importLocalFile({
    required String projectDir,
    required String pickedPath,
    required String title,
    String? artist,
  }) async {
    final ext = p.extension(pickedPath);
    final fileName = 'music${ext.isEmpty ? '.mp3' : ext}';
    final dest = File(p.join(projectDir, fileName));
    await File(pickedPath).copy(dest.path);

    return ProjectMusic(
      title: title,
      artist: artist,
      fileName: fileName,
      source: MusicSource.local,
    );
  }

  Future<ProjectMusic> importJamendoTrack({
    required String projectDir,
    required RoyaltyFreeTrack track,
  }) async {
    if (!track.downloadAllowed) {
      throw StateError('jamendo_download_not_allowed');
    }

    final uri = jamendo.downloadUri(track.id);
    final response = await (_client ?? http.Client()).get(uri);
    if (response.statusCode != 200) {
      throw StateError('jamendo_download_failed:${response.statusCode}');
    }

    const fileName = 'music.mp3';
    final dest = File(p.join(projectDir, fileName));
    await dest.writeAsBytes(response.bodyBytes, flush: true);

    return ProjectMusic(
      title: track.title,
      artist: track.artist,
      fileName: fileName,
      licenseUrl: track.licenseUrl,
      source: MusicSource.jamendo,
      externalId: track.id,
    );
  }

  static String musicPath(String projectDir, ProjectMusic music) {
    return p.join(projectDir, music.fileName);
  }
}
