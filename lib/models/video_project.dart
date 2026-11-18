import 'package:aveditor/models/canvas_ratio.dart';
import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/clip_trim.dart';
import 'package:aveditor/models/export_preset.dart';
import 'package:aveditor/models/media_asset.dart';
import 'package:aveditor/models/project_music.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/utils/clip_segment_ops.dart';
import 'package:aveditor/utils/timeline_math.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// On-disk project format version (2 = multi-source media assets).
const int kProjectFileVersion = 2;

/// Legacy single-file name still accepted when migrating v1 projects.
const String kProjectSourceFileName = 'source.mp4';

/// Directory under the project folder for per-clip media files.
const String kProjectMediaDirName = 'media';

CanvasRatio _canvasFromJson(Object? raw) {
  if (raw is! String) return CanvasRatio.original;
  for (final ratio in CanvasRatio.values) {
    if (ratio.name == raw) return ratio;
  }
  return CanvasRatio.original;
}

/// A saved edit session backed by files on disk.
class VideoProject {
  VideoProject({
    required this.id,
    required this.sourcePath,
    required this.duration,
    ClipTrim? trim,
    List<ClipSegment>? segments,
    List<MediaAsset>? mediaAssets,
    List<TextOverlay>? overlays,
    List<ProjectMusic>? musicTracks,
    ProjectMusic? backgroundMusic,
    this.preset = ExportPreset.youtubeShorts,
    this.canvas = CanvasRatio.original,
    this.rotation = 0,
    this.name,
    DateTime? updatedAt,
    this.lastExportedAt,
  })  : mediaAssets = mediaAssets ?? [],
        segments = segments ??
            segmentsFromTrim(
              start: trim?.start ?? Duration.zero,
              end: trim?.end ?? duration,
            ),
        overlays = overlays ?? [],
        musicTracks = musicTracks ??
            (backgroundMusic == null ? <ProjectMusic>[] : [backgroundMusic]),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;

  /// Absolute path used as the project directory anchor.
  ///
  /// For v2 projects this is typically the first video asset (or any media
  /// file) so [projectDir] / relative media paths resolve. Legacy v1 projects
  /// point at `source.mp4`.
  final String sourcePath;

  /// Packed timeline length (sum of segment durations).
  Duration duration;
  final List<ClipSegment> segments;
  final List<MediaAsset> mediaAssets;
  final List<TextOverlay> overlays;

  /// CapCut-style audio clips on a dedicated music track.
  final List<ProjectMusic> musicTracks;
  ExportPreset preset;

  /// Preview and export frame. [CanvasRatio.original] uses the source picture.
  CanvasRatio canvas;

  /// Clockwise rotation of the video frame about its centre, in radians.
  double rotation;

  DateTime updatedAt;

  /// Last successful export time. Null until the user has exported once.
  /// Used for home “continue draft” when [updatedAt] is newer than this.
  DateTime? lastExportedAt;

  /// True when the project has never been exported, or was edited after export.
  bool get isDraft {
    final exported = lastExportedAt;
    if (exported == null) return true;
    return updatedAt.isAfter(exported);
  }

  /// User-given project name. Null until the user names it (asked on the
  /// first back press out of the editor).
  String? name;

  /// Project folder containing `project.json` and `media/`.
  String get projectDir {
    final dir = p.dirname(sourcePath);
    // Primary probe file may live under media/; the project root is the parent.
    if (p.basename(dir) == kProjectMediaDirName) {
      return p.dirname(dir);
    }
    return dir;
  }

  /// Path of [sourcePath] relative to [projectDir] (e.g. `media/<id>.mp4`).
  String get sourceFileName {
    final root = projectDir;
    final normalizedRoot = p.normalize(root);
    final normalizedSource = p.normalize(sourcePath);
    if (normalizedSource == normalizedRoot ||
        normalizedSource.startsWith('$normalizedRoot${p.separator}')) {
      return p.relative(normalizedSource, from: normalizedRoot);
    }
    return p.basename(sourcePath);
  }

  MediaAsset? assetById(String? id) {
    if (id == null) return null;
    for (final asset in mediaAssets) {
      if (asset.id == id) return asset;
    }
    return null;
  }

  /// Absolute path for a media asset inside this project.
  String absoluteMediaPath(MediaAsset asset) {
    if (p.isAbsolute(asset.fileName)) return asset.fileName;
    return p.join(projectDir, asset.fileName);
  }

  /// Resolve the file path for a timeline segment.
  String? pathForSegment(ClipSegment segment) {
    final asset = assetById(segment.mediaId);
    if (asset != null) return absoluteMediaPath(asset);
    // Legacy fallback: single master file.
    if (mediaAssets.isEmpty) return sourcePath;
    return null;
  }

  /// Primary video path for canvas / probe (first video asset, else sourcePath).
  String get primaryVideoPath {
    for (final asset in mediaAssets) {
      if (asset.isVideo) return absoluteMediaPath(asset);
    }
    if (mediaAssets.isNotEmpty) {
      return absoluteMediaPath(mediaAssets.first);
    }
    return sourcePath;
  }

  ClipTrim get trim {
    if (segments.isEmpty) {
      return ClipTrim(start: Duration.zero, end: duration);
    }
    return ClipTrim(start: segments.first.start, end: segments.last.end);
  }

  Duration get trimmedDuration =>
      segments.isEmpty ? Duration.zero : exportTimelineDuration(segments);

  void setTrimStart(Duration start) {
    if (segments.isEmpty) return;
    final first = segments.first;
    final asset = assetById(first.mediaId);
    if (asset != null && asset.isImage) return;
    var clamped = start;
    if (clamped < Duration.zero) clamped = Duration.zero;
    final maxStart = first.end - minTrimDuration;
    if (clamped > maxStart) clamped = maxStart;
    if (clamped >= first.end) return;
    segments[0] = first.copyWith(start: clamped);
  }

  void setTrimEnd(Duration end) {
    if (segments.isEmpty) return;
    final last = segments.last;
    final asset = assetById(last.mediaId);
    final maxEnd = asset?.maxClipEnd ?? duration;
    var clamped = end;
    if (clamped > maxEnd) clamped = maxEnd;
    final minEnd = last.start + minTrimDuration;
    if (clamped < minEnd) clamped = minEnd;
    if (clamped <= last.start) return;
    segments[segments.length - 1] = last.copyWith(end: clamped);
  }

  void touch() => updatedAt = DateTime.now();

  VideoProject withSourcePath(String sourcePath) {
    return VideoProject(
      id: id,
      sourcePath: sourcePath,
      duration: duration,
      segments: segments.map((segment) => segment.copyWith()).toList(),
      mediaAssets: mediaAssets.map((a) => a.copyWith()).toList(),
      overlays: List<TextOverlay>.from(overlays),
      musicTracks: musicTracks.map((track) => track.copyWith()).toList(),
      preset: preset,
      canvas: canvas,
      rotation: rotation,
      name: name,
      updatedAt: updatedAt,
      lastExportedAt: lastExportedAt,
    );
  }

  VideoProject copyWith({
    Duration? duration,
    List<ClipSegment>? segments,
    List<MediaAsset>? mediaAssets,
    List<TextOverlay>? overlays,
    List<ProjectMusic>? musicTracks,
    ExportPreset? preset,
    CanvasRatio? canvas,
    double? rotation,
    String? name,
    DateTime? updatedAt,
    DateTime? lastExportedAt,
    bool clearLastExportedAt = false,
  }) {
    return VideoProject(
      id: id,
      sourcePath: sourcePath,
      duration: duration ?? this.duration,
      segments: segments ?? this.segments.map((s) => s.copyWith()).toList(),
      mediaAssets:
          mediaAssets ?? this.mediaAssets.map((a) => a.copyWith()).toList(),
      overlays: overlays ?? List<TextOverlay>.from(this.overlays),
      musicTracks: musicTracks ??
          this.musicTracks.map((m) => m.copyWith()).toList(),
      preset: preset ?? this.preset,
      canvas: canvas ?? this.canvas,
      rotation: rotation ?? this.rotation,
      name: name ?? this.name,
      updatedAt: updatedAt ?? this.updatedAt,
      lastExportedAt: clearLastExportedAt
          ? null
          : (lastExportedAt ?? this.lastExportedAt),
    );
  }

  Map<String, dynamic> toJson() => {
        'version': kProjectFileVersion,
        'id': id,
        if (name != null) 'name': name,
        'updatedAt': updatedAt.toIso8601String(),
        if (lastExportedAt != null)
          'lastExportedAt': lastExportedAt!.toIso8601String(),
        'sourceFileName': sourceFileName,
        'durationMs':
            (segments.isEmpty ? duration : exportTimelineDuration(segments))
                .inMilliseconds,
        'trim': trim.toJson(),
        'mediaAssets': mediaAssets.map((a) => a.toJson()).toList(),
        'segments': segments.map((segment) => segment.toJson()).toList(),
        'rotation': rotation,
        'preset': preset.name,
        'canvas': canvas.name,
        'overlays': overlays.map((overlay) => overlay.toJson()).toList(),
        'musicTracks': musicTracks.map((m) => m.toJson()).toList(),
      };

  factory VideoProject.fromJson(
    Map<String, dynamic> json, {
    required String sourcePath,
  }) {
    final version = (json['version'] as num?)?.toInt() ?? 1;
    final duration = Duration(milliseconds: json['durationMs'] as int);
    final segmentJson = json['segments'] as List<dynamic>?;
    var segments = segmentJson == null
        ? segmentsFromTrim(
            start: Duration(
              milliseconds:
                  (json['trim'] as Map<String, dynamic>)['startMs'] as int,
            ),
            end: Duration(
              milliseconds:
                  (json['trim'] as Map<String, dynamic>)['endMs'] as int,
            ),
          )
        : segmentJson
            .map(
              (entry) => ClipSegment.fromJson(entry as Map<String, dynamic>),
            )
            .toList();

    final mediaJson = json['mediaAssets'] as List<dynamic>?;
    var mediaAssets = mediaJson == null
        ? <MediaAsset>[]
        : mediaJson
            .map((e) => MediaAsset.fromJson(e as Map<String, dynamic>))
            .toList();

    // v1 → v2: one legacy master file becomes a single MediaAsset.
    if (mediaAssets.isEmpty) {
      final legacyId = const Uuid().v4();
      final fileName = json['sourceFileName'] as String? ??
          p.basename(sourcePath);
      // Prefer the farthest out-point so a packed durationMs (v2) cannot
      // clamp a trimmed segment that still sits on the master file clock.
      var assetDuration = duration;
      for (final segment in segments) {
        if (segment.end > assetDuration) assetDuration = segment.end;
      }
      mediaAssets = [
        MediaAsset(
          id: legacyId,
          fileName: fileName,
          kind: MediaAssetKind.video,
          duration: assetDuration,
        ),
      ];
      segments = [
        for (final segment in segments)
          segment.mediaId == null
              ? segment.copyWith(mediaId: legacyId)
              : segment,
      ];
    } else if (version < 2) {
      final fallbackId = mediaAssets.first.id;
      segments = [
        for (final segment in segments)
          segment.mediaId == null
              ? segment.copyWith(mediaId: fallbackId)
              : segment,
      ];
    }

    final resolvedSegments = normalizeSegments(
      segments,
      mediaAssets: mediaAssets,
      sourceDuration: duration,
    );

    final musicJson = json['musicTracks'] as List<dynamic>?;
    final legacyMusic = json['backgroundMusic'] as Map<String, dynamic>?;
    final musicTracks = musicJson != null
        ? musicJson
            .map((e) => ProjectMusic.fromJson(e as Map<String, dynamic>))
            .toList()
        : legacyMusic == null
            ? <ProjectMusic>[]
            : [ProjectMusic.fromJson(legacyMusic)];

    final packed = resolvedSegments.isEmpty
        ? duration
        : exportTimelineDuration(resolvedSegments);

    return VideoProject(
      id: json['id'] as String,
      sourcePath: sourcePath,
      duration: packed,
      segments: resolvedSegments,
      mediaAssets: mediaAssets,
      overlays: resolveOverlayLanes(
        (json['overlays'] as List<dynamic>?)
                ?.map(
                  (entry) => TextOverlay.fromJson(entry as Map<String, dynamic>),
                )
                .toList() ??
            const [],
      ),
      musicTracks: musicTracks,
      preset: ExportPreset.values.byName(json['preset'] as String),
      canvas: _canvasFromJson(json['canvas']),
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
      name: json['name'] as String?,
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      lastExportedAt: json['lastExportedAt'] == null
          ? null
          : DateTime.parse(json['lastExportedAt'] as String),
    );
  }
}
