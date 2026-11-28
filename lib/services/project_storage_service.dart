import 'dart:convert';
import 'dart:io';

import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/media_asset.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/services/library_media_resolver.dart';
import 'package:aveditor/services/media_concat_service.dart';
import 'package:aveditor/services/media_pick_batch.dart';
import 'package:aveditor/services/video_frame_grab.dart';
import 'package:aveditor/services/playback_fallback_transcoder.dart';
import 'package:aveditor/utils/av_editor_log.dart';
import 'package:aveditor/utils/clip_segment_ops.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Summary shown on the home screen for a resumable project.
@immutable
class ProjectSummary {
  const ProjectSummary({
    required this.id,
    required this.updatedAt,
    required this.overlayCount,
    required this.sourceExists,
    this.name,
    this.coverTimeMs = 0,
    this.lastExportedAt,
  });

  final String id;
  final DateTime updatedAt;
  final int overlayCount;
  final bool sourceExists;

  /// User-given name, or null for a project that was never named.
  final String? name;

  /// Source time of the project's first frame (start of the first clip),
  /// used for the home-screen cover thumbnail.
  final int coverTimeMs;

  /// Null until the first successful export.
  final DateTime? lastExportedAt;

  /// Never exported, or edited after the last export.
  bool get isDraft {
    final exported = lastExportedAt;
    if (exported == null) return true;
    return updatedAt.isAfter(exported);
  }
}

/// Persists edit projects as JSON + media (copied or library-referenced).
class ProjectStorageService {
  const ProjectStorageService({
    this.rootOverride,
    this.transcoder,
    this.libraryResolver = const LibraryMediaResolver(),
  });

  final Directory? rootOverride;
  final PlaybackFallbackTranscoder? transcoder;
  final LibraryMediaResolver libraryResolver;

  static const _rootDirName = 'aveditor';
  static const _indexFileName = 'index.json';

  /// Creates a new on-disk project from a picked video and returns its id.
  Future<String> createFromImport(
    String pickedPath, {
    void Function(double progress)? onProgress,
    MediaConcatService? concat,
  }) {
    return createFromImports(
      MediaPickBatch.paths([pickedPath]),
      onProgress: onProgress,
      concat: concat,
    );
  }

  /// Creates a project from one or more videos/images in pick order.
  ///
  /// Gallery library picks ([MediaPickItem.copyIntoProject] false) store a
  /// reference — no Documents byte copy. Camera / file picks still copy into
  /// `media/<id>.<ext>`. Images hold [kDefaultImageHoldDuration] (no bake).
  Future<String> createFromImports(
    MediaPickBatch batch, {
    void Function(double progress)? onProgress,
    MediaConcatService? concat,
  }) async {
    final items = batch.items;
    if (items.isEmpty) throw StateError('empty_video');

    final id = const Uuid().v4();
    final dir = await _projectDir(id);
    await dir.create(recursive: true);
    final mediaDir = Directory(p.join(dir.path, kProjectMediaDirName));
    await mediaDir.create(recursive: true);

    final probe = concat ?? const MediaConcatService();
    final mediaAssets = <MediaAsset>[];
    final segments = <ClipSegment>[];

    for (var i = 0; i < items.length; i++) {
      onProgress?.call(i / (items.length + 1));
      final imported = await _importItem(
        items[i],
        projectDir: dir,
        probe: probe,
        imageHoldDuration: batch.imageHoldDuration,
      );
      mediaAssets.add(imported.asset);
      segments.add(imported.segment);
    }

    if (segments.isEmpty || mediaAssets.isEmpty) {
      throw StateError('empty_video');
    }
    onProgress?.call(1);

    final sourcePath = await _anchorSourcePath(dir, mediaAssets: mediaAssets);

    final packed = exportTimelineDuration(segments);
    final project = VideoProject(
      id: id,
      sourcePath: sourcePath,
      duration: packed,
      segments: segments,
      mediaAssets: mediaAssets,
    );
    await save(project);
    final stored = await ensurePlayableSource(project, onProgress: onProgress);
    return stored.id;
  }

  /// Appends picks to [project] after the last segment.
  ///
  /// Gallery library references skip the Documents copy; other picks copy.
  Future<VideoProject> appendImports(
    VideoProject project,
    MediaPickBatch batch, {
    void Function(double progress)? onProgress,
    MediaConcatService? concat,
  }) async {
    final items = batch.items;
    if (items.isEmpty) return project;

    final dir = await _projectDir(project.id);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final mediaDir = Directory(p.join(dir.path, kProjectMediaDirName));
    await mediaDir.create(recursive: true);

    final probe = concat ?? const MediaConcatService();
    final added = <MediaAsset>[];
    final newSegments = <ClipSegment>[];

    for (var i = 0; i < items.length; i++) {
      onProgress?.call(i / (items.length + 1));
      final imported = await _importItem(
        items[i],
        projectDir: dir,
        probe: probe,
        imageHoldDuration: batch.imageHoldDuration,
      );
      added.add(imported.asset);
      newSegments.add(imported.segment);
    }

    if (added.isEmpty) return project;

    project.mediaAssets.addAll(added);
    project.segments.addAll(newSegments);
    final packed = exportTimelineDuration(project.segments);
    if (packed > Duration.zero) {
      project.duration = packed;
    }

    // Keep projectDir stable if sourcePath was only a library session file.
    final anchored = await _anchorSourcePath(
      dir,
      mediaAssets: project.mediaAssets,
    );
    final withSource = anchored == project.sourcePath
        ? project
        : project.withSourcePath(anchored);

    onProgress?.call(items.length / (items.length + 1));
    final playable =
        await ensurePlayableSource(withSource, onProgress: onProgress);
    await save(playable);
    onProgress?.call(1);
    return playable;
  }

  Future<({MediaAsset asset, ClipSegment segment})> _importItem(
    MediaPickItem item, {
    required Directory projectDir,
    required MediaConcatService probe,
    Duration? imageHoldDuration,
  }) async {
    final pickedPath = item.path.trim();
    final picked = File(pickedPath);
    if (!await picked.exists() || await picked.length() == 0) {
      throw StateError('empty_video');
    }

    final isImage = MediaConcatService.isImagePath(pickedPath);
    final assetId = const Uuid().v4();
    final reference = !item.copyIntoProject &&
        item.libraryAssetId != null &&
        item.libraryAssetId!.trim().isNotEmpty;

    late final String storedName;
    late final String playablePath;
    if (reference) {
      // CapCut-style: keep the session path; durable key is libraryAssetId.
      storedName = pickedPath;
      playablePath = pickedPath;
      avEditorLog(
        'store library reference id=${item.libraryAssetId} path=$pickedPath',
      );
    } else {
      final ext = p.extension(pickedPath);
      storedName = p.join(
        kProjectMediaDirName,
        '$assetId${ext.isEmpty ? (isImage ? '.jpg' : '.mp4') : ext}',
      );
      playablePath = p.join(projectDir.path, storedName);
      await picked.copy(playablePath);
      if (!await File(playablePath).exists() ||
          await File(playablePath).length() == 0) {
        throw StateError('empty_video');
      }
    }

    Duration assetDuration = Duration.zero;
    if (!isImage) {
      final known = item.duration;
      if (known != null && known > Duration.zero) {
        assetDuration = known;
      } else {
        assetDuration =
            await probe.probeDuration(playablePath) ?? Duration.zero;
      }
      if (assetDuration <= Duration.zero) {
        throw StateError('empty_video');
      }
    }

    final asset = MediaAsset(
      id: assetId,
      fileName: storedName,
      kind: isImage ? MediaAssetKind.image : MediaAssetKind.video,
      duration: assetDuration,
      libraryAssetId: reference ? item.libraryAssetId!.trim() : null,
    );
    final imageHold = imageHoldDuration ?? kDefaultImageHoldDuration;
    final segment = ClipSegment(
      mediaId: assetId,
      start: Duration.zero,
      end: isImage ? imageHold : assetDuration,
    );
    return (asset: asset, segment: segment);
  }

  /// Project-folder anchor so [VideoProject.projectDir] stays stable when media
  /// paths are absolute library session files outside Documents.
  Future<String> _anchorSourcePath(
    Directory dir, {
    required List<MediaAsset> mediaAssets,
  }) async {
    // Prefer an in-project copied file so sourcePath remains playable.
    for (final asset in mediaAssets) {
      if (p.isAbsolute(asset.fileName)) continue;
      final path = p.join(dir.path, asset.fileName);
      if (await File(path).exists()) return path;
    }

    final anchorPath = p.join(dir.path, kProjectAnchorFileName);
    final anchor = File(anchorPath);
    if (!await anchor.exists()) {
      await anchor.create();
    }
    return anchorPath;
  }

  /// Re-resolves gallery library assets whose session paths expired.
  Future<VideoProject> resolveLibraryReferences(VideoProject project) async {
    var changed = false;
    final nextAssets = <MediaAsset>[];
    for (final asset in project.mediaAssets) {
      if (!asset.isLibraryReference) {
        nextAssets.add(asset);
        continue;
      }
      final current = project.absoluteMediaPath(asset);
      if (await File(current).exists() && await File(current).length() > 0) {
        nextAssets.add(asset);
        continue;
      }
      final resolved = await libraryResolver.resolve(asset.libraryAssetId!);
      if (resolved == null ||
          !await File(resolved).exists() ||
          await File(resolved).length() == 0) {
        avEditorLog(
          'library media unavailable id=${asset.libraryAssetId} '
          'asset=${asset.id}',
        );
        nextAssets.add(asset);
        continue;
      }
      avEditorLog(
        'library media re-resolved id=${asset.libraryAssetId} path=$resolved',
      );
      nextAssets.add(asset.copyWith(fileName: resolved));
      changed = true;
    }
    if (!changed) return project;
    final dir = await _projectDir(project.id);
    final anchored = await _anchorSourcePath(dir, mediaAssets: nextAssets);
    final updated =
        project.copyWith(mediaAssets: nextAssets).withSourcePath(anchored);
    // Persist new session paths without bumping updatedAt (not a user edit).
    await _writeProjectJson(updated);
    return updated;
  }

  /// Replaces unplayable video assets with H.264 SDR copies in place.
  Future<VideoProject> ensurePlayableSource(
    VideoProject project, {
    void Function(double progress)? onProgress,
  }) async {
    final converter = transcoder ?? const PlaybackFallbackTranscoder();
    if (project.mediaAssets.isEmpty) {
      if (!await converter.shouldReplace(project.sourcePath)) return project;
      avEditorLog('store playable source ${project.sourcePath}');
      final output = await converter.transcode(
        project.sourcePath,
        onProgress: onProgress,
      );
      if (output == project.sourcePath) return project;
      final updated = project.withSourcePath(output);
      await save(updated);
      return updated;
    }

    var changed = false;
    final nextAssets = <MediaAsset>[];
    for (var i = 0; i < project.mediaAssets.length; i++) {
      final asset = project.mediaAssets[i];
      if (asset.isImage) {
        nextAssets.add(asset);
        continue;
      }
      final path = project.absoluteMediaPath(asset);
      if (!await converter.shouldReplace(path)) {
        nextAssets.add(asset);
        continue;
      }
      avEditorLog('store playable media ${asset.fileName}');
      // Library references must land inside the project folder after convert.
      final transcodeInput = await _materializeForTranscode(
        project,
        asset,
        path,
      );
      final output = await converter.transcode(
        transcodeInput,
        onProgress: onProgress == null
            ? null
            : (t) => onProgress((i + t) / project.mediaAssets.length),
      );
      if (output == path && !asset.isLibraryReference) {
        nextAssets.add(asset);
        continue;
      }
      // Transcoder writes beside the source; point the asset at the new file.
      final normalizedRoot = p.normalize(project.projectDir);
      final normalizedOut = p.normalize(output);
      final relative =
          normalizedOut == normalizedRoot ||
              normalizedOut.startsWith('$normalizedRoot${p.separator}')
          ? p.relative(output, from: project.projectDir)
          : output;
      nextAssets.add(
        asset.copyWith(
          fileName: relative,
          clearLibraryAssetId: true,
        ),
      );
      changed = true;
    }
    if (!changed) return project;
    final dir = await _projectDir(project.id);
    final anchored = await _anchorSourcePath(dir, mediaAssets: nextAssets);
    final updated =
        project.copyWith(mediaAssets: nextAssets).withSourcePath(anchored);
    await save(updated);
    return updated;
  }

  /// Copies a library-referenced file into `media/` before Android transcode.
  Future<String> _materializeForTranscode(
    VideoProject project,
    MediaAsset asset,
    String path,
  ) async {
    if (!asset.isLibraryReference && !p.isAbsolute(asset.fileName)) {
      return path;
    }
    final ext = p.extension(path);
    final relative = p.join(
      kProjectMediaDirName,
      '${asset.id}${ext.isEmpty ? '.mp4' : ext}',
    );
    final dest = p.join(project.projectDir, relative);
    final destFile = File(dest);
    if (!await destFile.parent.exists()) {
      await destFile.parent.create(recursive: true);
    }
    if (p.normalize(path) != p.normalize(dest)) {
      await File(path).copy(dest);
    }
    return dest;
  }

  Future<VideoProject?> load(String projectId) async {
    final file = await _projectFile(projectId);
    if (!await file.exists()) return null;

    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final dir = await _projectDir(projectId);
    final sourceFileName =
        json['sourceFileName'] as String? ?? kProjectSourceFileName;
    var sourcePath = p.isAbsolute(sourceFileName)
        ? sourceFileName
        : p.join(dir.path, sourceFileName);

    // v2: primary file may live under media/, or be an absolute library path.
    if (!await File(sourcePath).exists()) {
      final mediaJson = json['mediaAssets'] as List<dynamic>?;
      if (mediaJson != null) {
        for (final raw in mediaJson) {
          if (raw is! Map) continue;
          final name = raw['fileName'] as String?;
          if (name == null) continue;
          final candidate = p.isAbsolute(name) ? name : p.join(dir.path, name);
          if (await File(candidate).exists()) {
            sourcePath = candidate;
            break;
          }
        }
      }
    }

    // Library-only projects keep a project.anchor marker for projectDir.
    if (!await File(sourcePath).exists()) {
      final anchor = p.join(dir.path, kProjectAnchorFileName);
      if (await File(anchor).exists()) {
        sourcePath = anchor;
      } else if (json['mediaAssets'] is List &&
          (json['mediaAssets'] as List).isNotEmpty) {
        // Create the anchor so projectDir resolves; media may re-resolve below.
        await File(anchor).create();
        sourcePath = anchor;
      }
    }
    if (!await File(sourcePath).exists()) return null;

    final project = VideoProject.fromJson(json, sourcePath: sourcePath);
    return resolveLibraryReferences(project);
  }

  Future<ProjectSummary?> loadLastSummary() async {
    final index = await _readIndex();
    final id = index['lastProjectId'] as String?;
    if (id == null) return null;
    return loadSummary(id);
  }

  /// All saved projects, newest first. Skips folders without a valid source.
  Future<List<ProjectSummary>> listSummaries() async {
    final root = await _rootDir();
    final projectsRoot = Directory(p.join(root.path, 'projects'));
    if (!await projectsRoot.exists()) return const [];

    final summaries = <ProjectSummary>[];
    await for (final entity in projectsRoot.list()) {
      if (entity is! Directory) continue;
      final id = p.basename(entity.path);
      if (id.isEmpty) continue;
      final summary = await loadSummary(id);
      if (summary == null || !summary.sourceExists) continue;
      summaries.add(summary);
    }
    summaries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return summaries;
  }

  Future<ProjectSummary?> loadSummary(String projectId) async {
    final project = await load(projectId);
    if (project == null) return null;

    final primary = project.primaryVideoPath;
    final sourceExists = await File(primary).exists() &&
        await File(primary).length() > 0 &&
        p.basename(primary) != kProjectAnchorFileName;

    return ProjectSummary(
      id: project.id,
      updatedAt: project.updatedAt,
      overlayCount: project.overlays.length,
      sourceExists: sourceExists,
      name: project.name,
      coverTimeMs: project.segments.isEmpty
          ? 0
          : project.segments.first.start.inMilliseconds,
      lastExportedAt: project.lastExportedAt,
    );
  }

  /// Marks a successful export so home can demote the project from “draft”.
  ///
  /// Writes without [save]'s [VideoProject.touch] — otherwise `updatedAt`
  /// would land after `lastExportedAt` and the project would stay a draft.
  Future<void> markExported(String projectId, {DateTime? at}) async {
    final project = await load(projectId);
    if (project == null) return;
    final when = at ?? DateTime.now();
    project.lastExportedAt =
        project.updatedAt.isAfter(when) ? project.updatedAt : when;
    final file = await _projectFile(project.id);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(project.toJson()),
      flush: true,
    );
  }


  /// Cover thumbnail for the home list: one frame at the start of the first
  /// clip, cached as `cover_<ms>.jpg` in the project folder. Trimming the
  /// front changes the time and so the file name, which refreshes the cover.
  /// Returns null when no frame can be read.
  Future<String?> coverThumbnail(
    ProjectSummary summary, {
    VideoFrameGrab grab = const VideoFrameGrab(),
  }) async {
    final dir = await _projectDir(summary.id);
    if (!await dir.exists()) return null;

    final project = await load(summary.id);
    if (project == null) return null;
    final coverPath = project.segments.isEmpty
        ? project.primaryVideoPath
        : (project.pathForSegment(project.segments.first) ??
            project.primaryVideoPath);
    final source = File(coverPath);
    if (!await source.exists()) return null;
    final sourceSize = await source.length();
    final target = p.join(
      dir.path,
      'cover_${summary.coverTimeMs}_$sourceSize.jpg',
    );
    final file = File(target);
    if (await file.exists() && await file.length() > 0) return target;

    // Drop covers for older first-frame times / previous source bytes.
    await for (final entity in dir.list()) {
      final name = p.basename(entity.path);
      if (entity is File &&
          name.startsWith('cover_') &&
          name.endsWith('.jpg')) {
        await entity.delete();
      }
    }

    final first = project.segments.isEmpty ? null : project.segments.first;
    final firstAsset =
        first == null ? null : project.assetById(first.mediaId);
    final generated = firstAsset != null && firstAsset.isImage
        ? coverPath // still: use the image file itself as cover when possible
        : await grab.jpegFile(
            video: coverPath,
            thumbnailPath: target,
            maxWidth: 240,
            timeMs: summary.coverTimeMs,
            quality: 70,
            accurate: true,
          );
    if (firstAsset != null && firstAsset.isImage) {
      try {
        await File(coverPath).copy(target);
        return target;
      } catch (_) {
        return coverPath;
      }
    }
    if (generated == null) return null;
    if (generated != target) {
      try {
        await File(generated).copy(target);
        return target;
      } catch (_) {
        return generated;
      }
    }
    return target;
  }

  Future<void> save(VideoProject project) async {
    project.touch();
    await _writeProjectJson(project);
    await _setLastProjectId(project.id);
  }

  Future<void> _writeProjectJson(VideoProject project) async {
    final dir = await _projectDir(project.id);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = await _projectFile(project.id);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(project.toJson()),
      flush: true,
    );
  }

  Future<void> delete(String projectId) async {
    final dir = await _projectDir(projectId);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }

    final index = await _readIndex();
    if (index['lastProjectId'] == projectId) {
      index.remove('lastProjectId');
      await _writeIndex(index);
    }
  }

  Future<Directory> _rootDir() async {
    final override = rootOverride;
    if (override != null) {
      if (!await override.exists()) {
        await override.create(recursive: true);
      }
      return override;
    }

    final docs = await getApplicationDocumentsDirectory();
    final root = Directory(p.join(docs.path, _rootDirName));
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    return root;
  }

  Future<Directory> projectDirectory(String projectId) =>
      _projectDir(projectId);

  Future<Directory> _projectDir(String projectId) async {
    return Directory(p.join((await _rootDir()).path, 'projects', projectId));
  }

  Future<File> _projectFile(String projectId) async {
    return File(p.join((await _projectDir(projectId)).path, 'project.json'));
  }

  Future<File> _indexFile() async {
    return File(p.join((await _rootDir()).path, _indexFileName));
  }

  Future<Map<String, dynamic>> _readIndex() async {
    final file = await _indexFile();
    if (!await file.exists()) return {};
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  Future<void> _writeIndex(Map<String, dynamic> index) async {
    final file = await _indexFile();
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(index),
      flush: true,
    );
  }

  Future<void> _setLastProjectId(String projectId) async {
    final index = await _readIndex();
    index['lastProjectId'] = projectId;
    await _writeIndex(index);
  }
}
