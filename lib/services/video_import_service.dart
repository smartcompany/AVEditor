import 'dart:io';

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

    try {
      final file = await _picker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 10),
      );
      if (file == null) return null;
      return _resolveUsableVideoPath(file);
    } catch (e) {
      if (Platform.isIOS) {
        return pickFromFiles();
      }
      rethrow;
    }
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
    return _resolveUsableVideoPath(file);
  }

  Future<String?> pickFromFiles() async {
    const group = XTypeGroup(
      label: 'videos',
      extensions: ['mp4', 'mov', 'm4v', 'webm', 'mkv'],
    );
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null) return null;
    return _resolveUsableVideoPath(file);
  }

  Future<String?> _resolveUsableVideoPath(XFile file) async {
    final rawPath = file.path;
    if (rawPath.isNotEmpty) {
      final rawFile = File(rawPath);
      if (await rawFile.exists()) {
        return rawPath;
      }
    }

    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      return null;
    }

    final dir = await getTemporaryDirectory();
    final name = file.name;
    final ext = p.extension(name).isNotEmpty ? p.extension(name) : '.mp4';
    final tempPath = p.join(
      dir.path,
      'import_${DateTime.now().millisecondsSinceEpoch}$ext',
    );
    final tempFile = File(tempPath);
    await tempFile.writeAsBytes(bytes, flush: true);
    return tempFile.path;
  }

  Future<void> _requestMobileMediaPermissions() async {
    if (kIsWeb) {
      return;
    }
    if (Platform.isIOS || Platform.isAndroid) {
      await [
        Permission.photos,
        Permission.videos,
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
