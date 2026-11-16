import 'dart:io';

import 'package:aveditor/services/media_concat_service.dart';
import 'package:aveditor/utils/av_editor_log.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// Picks videos and images from gallery, camera, or filesystem.
class VideoImportService {
  VideoImportService({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  static const _fileExtensions = [
    ...MediaConcatService.videoExtensions,
    ...MediaConcatService.imageExtensions,
  ];

  /// Gallery multi-select for videos and photos. Empty when cancelled.
  Future<List<String>> pickFromGallery() async {
    if (!Platform.isMacOS) {
      await _requestMobileMediaPermissions();
    }

    final files = await _picker.pickMultipleMedia();
    if (files.isEmpty) return const [];
    return _materializeAll(files);
  }

  /// Camera still returns a single video path list.
  Future<List<String>> pickFromCamera() async {
    if (Platform.isMacOS) {
      return const [];
    }

    await _requestCameraPermission();
    final file = await _picker.pickVideo(
      source: ImageSource.camera,
      maxDuration: const Duration(minutes: 10),
    );
    if (file == null) return const [];
    return [await materializeImport(file)];
  }

  Future<List<String>> pickFromFiles() async {
    final extensions = [
      for (final ext in _fileExtensions) ext.replaceFirst('.', ''),
    ];
    final group = XTypeGroup(label: 'media', extensions: extensions);
    final files = await openFiles(acceptedTypeGroups: [group]);
    if (files.isEmpty) return const [];
    return _materializeAll(files);
  }

  Future<List<String>> _materializeAll(List<XFile> files) async {
    final paths = <String>[];
    for (final file in files) {
      paths.add(await materializeImport(file));
    }
    return paths;
  }

  static var _materializeSeq = 0;

  /// Copies the picker result into an app-owned temp file.
  ///
  /// Gallery/camera paths are often ephemeral (Photos export, content URIs).
  /// Reusing them directly leads to intermittent "could not open video" errors.
  Future<String> materializeImport(XFile file) async {
    final dir = await getTemporaryDirectory();
    final ext = _extensionFor(file);
    _materializeSeq += 1;
    final destPath = p.join(
      dir.path,
      'import_${DateTime.now().millisecondsSinceEpoch}_$_materializeSeq$ext',
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
    if (mime.startsWith('image/')) {
      if (mime.contains('png')) return '.png';
      if (mime.contains('webp')) return '.webp';
      if (mime.contains('heic') || mime.contains('heif')) return '.heic';
      return '.jpg';
    }
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
