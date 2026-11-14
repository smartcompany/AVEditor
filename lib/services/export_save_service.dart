import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;

/// Saves exported videos to the photo library or a user-chosen file path.
class ExportSaveService {
  /// Rejects exports that never materialised on disk.
  static const minExportBytes = 1024;

  static const _channel = MethodChannel('aveditor/media_share');

  /// Saves the export. On iOS returns the Photos asset id, which lets other
  /// apps (Instagram) open that exact video; null elsewhere.
  Future<String?> saveExportedVideo(String filePath) async {
    await _assertExportReady(filePath);

    if (Platform.isIOS) {
      return _saveToPhotosWithId(filePath);
    }

    if (Platform.isAndroid) {
      await _saveToGallery(filePath);
      return null;
    }

    await _saveOnMacOS(filePath);
    return null;
  }

  Future<String?> _saveToPhotosWithId(String filePath) async {
    try {
      return await _channel.invokeMethod<String>('saveVideo', {
        'path': filePath,
      });
    } on PlatformException catch (e) {
      if (e.code == 'photos_permission_denied') {
        throw StateError('photos_permission_denied');
      }
      throw StateError('gallery_save_failed:${e.code}');
    } on MissingPluginException {
      // Older builds without the channel: plain save, no id.
      await _saveToGallery(filePath);
      return null;
    }
  }

  Future<void> _assertExportReady(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw StateError('export_file_missing');
    }
    if (await file.length() < minExportBytes) {
      throw StateError('export_file_empty');
    }
  }

  Future<void> _saveToGallery(String filePath) async {
    try {
      // Camera-roll save only needs add access. `toAlbum: true` asks for read
      // access to arbitrary albums and fails when the user picks "Add Photos
      // Only" on iOS.
      if (!await Gal.hasAccess()) {
        final granted = await Gal.requestAccess();
        if (!granted) {
          throw StateError('photos_permission_denied');
        }
      }

      await Gal.putVideo(filePath);
    } on GalException catch (e) {
      if (e.type == GalExceptionType.accessDenied) {
        throw StateError('photos_permission_denied');
      }
      throw StateError('gallery_save_failed:${e.type.code}');
    }
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
