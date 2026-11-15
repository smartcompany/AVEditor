import 'dart:io';

import 'package:aveditor/utils/av_editor_log.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// Picks a video from gallery, camera, or filesystem (macOS/desktop).
class VideoImportService {
  VideoImportService({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  Future<String?> pickFromGallery() async {
    if (!Platform.isMacOS) {
      await _requestMobileMediaPermissions();
    }

    final file = await _picker.pickVideo(source: ImageSource.gallery);
    if (file == null) return null;
    return materializeImport(file);
  }

  Future<String?> pickFromCamera() async {
    if (Platform.isMacOS) {
      return null;
    }

    await _requestCameraPermission();
    final file = await _picker.pickVideo(
      source: ImageSource.camera,
      maxDuration: const Duration(minutes: 10),
    );
    if (file == null) return null;
    return materializeImport(file);
  }

  Future<String?> pickFromFiles() async {
    const group = XTypeGroup(
      label: 'videos',
      extensions: ['mp4', 'mov', 'm4v', 'webm', 'mkv'],
    );
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null) return null;
    return materializeImport(file);
  }

  /// Copies the picker result into an app-owned temp file.
  ///
  /// Gallery/camera paths are often ephemeral (Photos export, content URIs).
  /// Reusing them directly leads to intermittent "could not open video" errors.
  Future<String> materializeImport(XFile file) async {
    final dir = await getTemporaryDirectory();
    final ext = _extensionFor(file);
    final destPath = p.join(
      dir.path,
      'import_${DateTime.now().millisecondsSinceEpoch}$ext',
    );
    final dest = File(destPath);

    try {
      await file.saveTo(destPath);
    } catch (error) {
      avEditorLog('import saveTo failed: $error');
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        throw StateError('empty_video');
      }
      await dest.writeAsBytes(bytes, flush: true);
    }

    if (!await dest.exists() || await dest.length() == 0) {
      final rawPath = file.path;
      if (rawPath.isNotEmpty) {
        final raw = File(rawPath);
        if (await raw.exists() && await raw.length() > 0) {
          await raw.copy(destPath);
        }
      }
    }

    final length = await dest.exists() ? await dest.length() : 0;
    if (length <= 0) {
      avEditorLog('import materialized empty path=$destPath src=${file.path}');
      throw StateError('empty_video');
    }
    avEditorLog('import materialized bytes=$length path=$destPath');
    return destPath;
  }

  String _extensionFor(XFile file) {
    final fromName = p.extension(file.name).trim();
    if (fromName.isNotEmpty) return fromName.toLowerCase();
    final fromPath = p.extension(file.path).trim();
    if (fromPath.isNotEmpty) return fromPath.toLowerCase();
    final mime = file.mimeType?.toLowerCase() ?? '';
    if (mime.contains('quicktime') || mime.contains('mov')) return '.mov';
    if (mime.contains('webm')) return '.webm';
    if (mime.contains('matroska') || mime.contains('mkv')) return '.mkv';
    return '.mp4';
  }

  Future<void> _requestMobileMediaPermissions() async {
    if (kIsWeb) {
      return;
    }
    // iOS PHPicker does not require Photos permission; requesting it can put
    // the app into limited-library mode and break some exports.
    if (Platform.isIOS) {
      return;
    }
    if (Platform.isAndroid) {
      await [
        Permission.videos,
        Permission.photos,
        Permission.storage,
      ].request();
    }
  }

  Future<void> _requestCameraPermission() async {
    if (Platform.isIOS || Platform.isAndroid) {
      await Permission.camera.request();
    }
  }
}
