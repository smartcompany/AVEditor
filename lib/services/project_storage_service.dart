import 'dart:convert';
import 'dart:io';

import 'package:aveditor/models/clip_trim.dart';
import 'package:aveditor/models/video_project.dart';
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
  });

  final String id;
  final DateTime updatedAt;
  final int overlayCount;
  final bool sourceExists;
}

/// Persists edit projects as JSON + a copied source video on disk.
class ProjectStorageService {
  const ProjectStorageService({this.rootOverride});

  final Directory? rootOverride;

  static const _rootDirName = 'aveditor';
  static const _indexFileName = 'index.json';

  /// Creates a new on-disk project from a picked video and returns its id.
  Future<String> createFromImport(String pickedPath) async {
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
    return id;
  }

  Future<VideoProject?> load(String projectId) async {
    final file = await _projectFile(projectId);
    if (!await file.exists()) return null;

    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final sourceFileName = json['sourceFileName'] as String? ?? kProjectSourceFileName;
    final sourcePath = p.join((await _projectDir(projectId)).path, sourceFileName);
    if (!await File(sourcePath).exists()) return null;

    return VideoProject.fromJson(json, sourcePath: sourcePath);
  }

  Future<ProjectSummary?> loadLastSummary() async {
    final index = await _readIndex();
    final id = index['lastProjectId'] as String?;
    if (id == null) return null;
    return loadSummary(id);
  }

  Future<ProjectSummary?> loadSummary(String projectId) async {
    final project = await load(projectId);
    if (project == null) return null;

    return ProjectSummary(
      id: project.id,
      updatedAt: project.updatedAt,
      overlayCount: project.overlays.length,
      sourceExists: await File(project.sourcePath).exists(),
    );
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

  Future<Directory> projectDirectory(String projectId) => _projectDir(projectId);

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
