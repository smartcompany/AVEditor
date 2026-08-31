import 'package:aveditor/models/video_project.dart';

/// Uploads exported MP4 to YouTube via videos.insert (resumable).
class YouTubeUploadService {
  Future<String> uploadShort({
    required String filePath,
    required String title,
    required String description,
    required String privacyStatus,
  }) async {
    // TODO: resumable upload with YouTube Data API v3
    throw UnimplementedError('YouTube upload not implemented yet');
  }

  Future<String> uploadProject({
    required VideoProject project,
    required String exportedPath,
    required String title,
    required String description,
    required String privacyStatus,
  }) {
    return uploadShort(
      filePath: exportedPath,
      title: title,
      description: description,
      privacyStatus: privacyStatus,
    );
  }
}
