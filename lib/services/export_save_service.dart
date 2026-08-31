import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

/// Saves exported videos to the photo library or a user-chosen file path.
class ExportSaveService {
  Future<void> saveExportedVideo(String filePath) async {
    if (Platform.isMacOS) {
      await _saveOnMacOS(filePath);
      return;
    }

    if (Platform.isIOS || Platform.isAndroid) {
      await _saveToGallery(filePath);
      return;
    }

    await _saveOnMacOS(filePath);
  }

  Future<void> _saveToGallery(String filePath) async {
    if (Platform.isAndroid) {
      final photos = await Permission.photos.request();
      final videos = await Permission.videos.request();
      if (!photos.isGranted && !videos.isGranted) {
        throw StateError('photos_permission_denied');
      }
    }

    if (Platform.isIOS) {
      final addOnly = await Permission.photosAddOnly.request();
      final photos = await Permission.photos.request();
      if (!addOnly.isGranted && !photos.isGranted) {
        throw StateError('photos_permission_denied');
      }
    }

    final hasAccess = await Gal.hasAccess(toAlbum: true);
    if (!hasAccess) {
      final granted = await Gal.requestAccess(toAlbum: true);
      if (!granted) {
        throw StateError('photos_permission_denied');
      }
    }

    await Gal.putVideo(filePath);
  }

  Future<void> _saveOnMacOS(String filePath) async {
    final source = File(filePath);
    final suggestedName = p.basename(filePath);
    final location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'MP4 video', extensions: ['mp4']),
      ],
    );
    if (location == null) {
      throw StateError('save_cancelled');
    }

    await source.copy(location.path);
  }
}
