import 'dart:convert';
import 'dart:io';

import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/media_asset.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/services/media_concat_service.dart';
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

/// Persists edit projects as JSON + a copied source video on disk.
class ProjectStorageService {
  const ProjectStorageService({this.rootOverride, this.transcoder});

  final Directory? rootOverride;
  final PlaybackFallbackTranscoder? transcoder;

  static const _rootDirName = 'aveditor';
  static const _indexFileName = 'index.json';

  /// Creates a new on-disk project from a picked video and returns its id.
  Future<String> createFromImport(
    String pickedPath, {
    void Function(double progress)? onProgress,
    MediaConcatService? concat,
  }) {
    return createFromImports(
      [pickedPath],
      onProgress: onProgress,
      concat: concat,
    );
  }

  /// Creates a project from one or more videos/images in pick order.
  ///
  /// Each pick is copied into `media/<id>.<ext>` as its own [MediaAsset].
  /// Images hold [kDefaultImageHoldDuration] on the timeline (no bake/concat).
  Future<String> createFromImports(
    List<String> pickedPaths, {
    void Function(double progress)? onProgress,
    MediaConcatService? concat,
  }) async {
    final paths = [
      for (final path in pickedPaths)
        if (path.trim().isNotEmpty) path.trim(),
    ];
    if (paths.isEmpty) throw StateError('empty_video');

    final id = const Uuid().v4();
    final dir = await _projectDir(id);
    await dir.create(recursive: true);
    final mediaDir = Directory(p.join(dir.path, kProjectMediaDirName));
    await mediaDir.create(recursive: true);

    final probe = concat ?? const MediaConcatService();
    final mediaAssets = <MediaAsset>[];
    final segments = <ClipSegment>[];
    String? primaryPath;

    for (var i = 0; i < paths.length; i++) {
      onProgress?.call(i / (paths.length + 1));
      final pickedPath = paths[i];
      final picked = File(pickedPath);
      if (!await picked.exists() || await picked.length() == 0) {
        throw StateError('empty_video');
      }

      final isImage = MediaConcatService.isImagePath(pickedPath);
      final assetId = const Uuid().v4();
      final ext = p.extension(pickedPath);
      final relativeName =
          p.join(kProjectMediaDirName, '$assetId${ext.isEmpty ? (isImage ? '.jpg' : '.mp4') : ext}');
      final destPath = p.join(dir.path, relativeName);
      await picked.copy(destPath);
      if (!await File(destPath).exists() || await File(destPath).length() == 0) {
        throw StateError('empty_video');
      }

      Duration assetDuration = Duration.zero;
      if (!isImage) {
        assetDuration =
            await probe.probeDuration(destPath) ?? Duration.zero;
        if (assetDuration <= Duration.zero) {
          throw StateError('empty_video');
        }
      }

      final asset = MediaAsset(
        id: assetId,
        fileName: relativeName,
        kind: isImage ? MediaAssetKind.image : MediaAssetKind.video,
        duration: assetDuration,
      );
      mediaAssets.add(asset);
      primaryPath ??= destPath;

      final clipEnd = isImage ? kDefaultImageHoldDuration : assetDuration;
      segments.add(
        ClipSegment(
          mediaId: assetId,
          start: Duration.zero,
          end: clipEnd,
        ),
      );
    }

    if (segments.isEmpty || primaryPath == null) {
      throw StateError('empty_video');
    }
    onProgress?.call(1);

    final packed = exportTimelineDuration(segments);
    final project = VideoProject(
      id: id,
      sourcePath: primaryPath,
      duration: packed,
      segments: segments,
      mediaAssets: mediaAssets,
    );
    await save(project);
    final stored = await ensurePlayableSource(project, onProgress: onProgress);
    return stored.id;
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
    String? primaryPath = project.sourcePath;
    for (var i = 0; i < project.mediaAssets.length; i++) {
      final asset = project.mediaAssets[i];
      if (asset.isImage) {
        nextAssets.add(asset);
        continue;
      }
      final path = project.absoluteMediaPath(asset);
      if (!await converter.shouldReplace(path)) {
        nextAssets.add(asset);
        primaryPath ??= path;
        continue;
      }
      avEditorLog('store playable media ${asset.fileName}');
      final output = await converter.transcode(
        path,
        onProgress: onProgress == null
            ? null
            : (t) => onProgress((i + t) / project.mediaAssets.length),
      );
      if (output == path) {
        nextAssets.add(asset);
        primaryPath ??= path;
        continue;
      }
      // Transcoder writes beside the source; point the asset at the new file.
      final relative = p.relative(output, from: project.projectDir);
      nextAssets.add(asset.copyWith(fileName: relative));
      primaryPath = output;
      changed = true;
    }
    if (!changed) return project;
    final updated = project.copyWith(mediaAssets: nextAssets).withSourcePath(
          primaryPath ?? project.sourcePath,
        );
    await save(updated);
    return updated;
  }

  Future<VideoProject?> load(String projectId) async {
    final file = await _projectFile(projectId);
    if (!await file.exists()) return null;

    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final dir = await _projectDir(projectId);
    final sourceFileName =
        json['sourceFileName'] as String? ?? kProjectSourceFileName;
    var sourcePath = p.join(dir.path, sourceFileName);

    // v2: primary file may live under media/.
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
    if (!await File(sourcePath).exists()) return null;

    return VideoProject.fromJson(json, sourcePath: sourcePath);
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

    return ProjectSummary(
      id: project.id,
      updatedAt: project.updatedAt,
      overlayCount: project.overlays.length,
      sourceExists: await File(project.sourcePath).exists(),
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
    final dir = await _projectDir(project.id);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final file = await _projectFile(project.id);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(project.toJson()),
      flush: true,
    );
    await _setLastProjectId(project.id);
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
