import 'dart:io';

import 'package:aveditor/screens/gallery_picker_screen.dart';
import 'package:aveditor/services/media_concat_service.dart';
import 'package:aveditor/services/media_pick_batch.dart';
import 'package:aveditor/utils/av_editor_log.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';

/// Picks videos and images from gallery, camera, or filesystem.
class VideoImportService {
  VideoImportService({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  static const _fileExtensions = [
    ...MediaConcatService.videoExtensions,
    ...MediaConcatService.imageExtensions,
  ];

  /// Custom gallery multi-select (library + background templates).
  /// Empty [MediaPickBatch.items] when cancelled.
  ///
  /// Gallery library picks are **referenced** (no temp/Documents byte copy).
  /// Background templates and camera/file picks still materialize copies.
  Future<MediaPickBatch> pickFromGallery(BuildContext context) async {
    final result = await GalleryPickerScreen.open(context);
    if (result == null || result.isEmpty) {
      return const MediaPickBatch(items: []);
    }

    if (result.backgroundPaths.isNotEmpty) {
      return MediaPickBatch.paths(
        result.backgroundPaths,
        imageHoldDuration: result.imageHoldDuration,
      );
    }

    final items = <MediaPickItem>[];
    for (final asset in result.assets) {
      items.add(await _galleryReference(asset));
    }
    return MediaPickBatch(items: items);
  }

  /// Resolve a Photos asset to a session-playable path without copying into
  /// app Documents. Prefers the local playable file over a full original export.
  Future<MediaPickItem> _galleryReference(AssetEntity asset) async {
    // CapCut-style: do not force originFile (full original export — slow).
    var file = await asset.file;
    file ??= await asset.originFile;
    if (file == null || !await file.exists() || await file.length() == 0) {
      avEditorLog('gallery asset unresolved id=${asset.id}');
      throw StateError('empty_video');
    }

    Duration? duration;
    if (asset.type == AssetType.video && asset.duration > 0) {
      duration = Duration(seconds: asset.duration);
    }

    avEditorLog(
      'gallery reference id=${asset.id} bytes=${await file.length()} '
      'durationMs=${duration?.inMilliseconds ?? -1} path=${file.path}',
    );
    return MediaPickItem(
      path: file.path,
      libraryAssetId: asset.id,
      duration: duration,
      copyIntoProject: false,
    );
  }

  /// Single video from the system gallery picker (share / re-post flows).
  /// Null when the user cancels.
  Future<String?> pickSingleVideoFromGallery() async {
    if (Platform.isMacOS) return null;
    final file = await _picker.pickVideo(source: ImageSource.gallery);
    if (file == null) return null;
    return materializeImport(file);
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
  /// Camera / file-picker / share paths can be ephemeral (content URIs).
  /// Gallery library picks skip this and use [MediaPickItem.copyIntoProject]
  /// false instead.
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

  Future<void> _requestCameraPermission() async {
    if (Platform.isIOS || Platform.isAndroid) {
      await Permission.camera.request();
    }
  }
}
