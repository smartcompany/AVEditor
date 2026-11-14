import 'dart:convert';
import 'dart:io';

import 'package:aveditor/models/clip_trim.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/services/video_frame_grab.dart';
import 'package:aveditor/services/playback_fallback_transcoder.dart';
import 'package:aveditor/utils/av_editor_log.dart';
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
  }) async {
    final id = const Uuid().v4();
    final dir = await _projectDir(id);
    await dir.create(recursive: true);

    final ext = p.extension(pickedPath);
    final sourceFileName = 'source${ext.isEmpty ? '.mp4' : ext}';
    final sourcePath = p.join(dir.path, sourceFileName);
    await File(pickedPath).copy(sourcePath);

    final project = VideoProject(
      id: id,
      sourcePath: sourcePath,
      duration: Duration.zero,
      trim: ClipTrim(start: Duration.zero, end: Duration.zero),
    );
    await save(project);
    final stored = await ensurePlayableSource(project, onProgress: onProgress);
    return stored.id;
  }

  /// Replaces a stored HEVC, ProRes, or HDR file with H.264 SDR.
  Future<VideoProject> ensurePlayableSource(
    VideoProject project, {
    void Function(double progress)? onProgress,
  }) async {
    final converter = transcoder ?? const PlaybackFallbackTranscoder();
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

  Future<VideoProject?> load(String projectId) async {
    final file = await _projectFile(projectId);
    if (!await file.exists()) return null;

    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final sourceFileName =
        json['sourceFileName'] as String? ?? kProjectSourceFileName;
    final sourcePath = p.join(
      (await _projectDir(projectId)).path,
      sourceFileName,
    );
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
    final target = p.join(dir.path, 'cover_${summary.coverTimeMs}.jpg');
    final file = File(target);
    if (await file.exists() && await file.length() > 0) return target;

    // Drop covers for older first-frame times.
    await for (final entity in dir.list()) {
      final name = p.basename(entity.path);
      if (entity is File &&
          name.startsWith('cover_') &&
          name.endsWith('.jpg')) {
        await entity.delete();
      }
    }

    final project = await load(summary.id);
    if (project == null) return null;
    final generated = await grab.jpegFile(
      video: project.sourcePath,
      thumbnailPath: target,
      maxWidth: 240,
      timeMs: summary.coverTimeMs,
      quality: 70,
    );
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
