import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/clip_trim.dart';
import 'package:aveditor/models/export_preset.dart';
import 'package:aveditor/models/project_music.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/utils/clip_segment_ops.dart';
import 'package:aveditor/utils/timeline_math.dart';
import 'package:path/path.dart' as p;

/// On-disk project format version.
const int kProjectFileVersion = 1;

/// Relative name of the source video inside a project folder.
const String kProjectSourceFileName = 'source.mp4';

/// A saved edit session backed by files on disk.
class VideoProject {
  VideoProject({
    required this.id,
    required this.sourcePath,
    required this.duration,
    ClipTrim? trim,
    List<ClipSegment>? segments,
    List<TextOverlay>? overlays,
    List<ProjectMusic>? musicTracks,
    ProjectMusic? backgroundMusic,
    this.preset = ExportPreset.youtubeShorts,
    this.rotation = 0,
    DateTime? updatedAt,
  })  : segments = segments ??
            segmentsFromTrim(
              start: trim?.start ?? Duration.zero,
              end: trim?.end ?? duration,
            ),
        overlays = overlays ?? [],
        musicTracks = musicTracks ??
            (backgroundMusic == null ? <ProjectMusic>[] : [backgroundMusic]),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;
  final String sourcePath;
  final Duration duration;
  final List<ClipSegment> segments;
  final List<TextOverlay> overlays;

  /// CapCut-style audio clips on a dedicated music track.
  final List<ProjectMusic> musicTracks;
  ExportPreset preset;

  /// Clockwise rotation of the video frame about its centre, in radians.
  double rotation;

  DateTime updatedAt;

  /// Basename of the source clip inside the project folder.
  String get sourceFileName => p.basename(sourcePath);

  ClipTrim get trim {
    if (segments.isEmpty) {
      return ClipTrim(start: Duration.zero, end: duration);
    }
    return ClipTrim(start: segments.first.start, end: segments.last.end);
  }

  Duration get trimmedDuration =>
      segments.isEmpty ? Duration.zero : totalKeptDuration(segments);

  void setTrimStart(Duration start) {
    if (segments.isEmpty) return;
    final first = segments.first;
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
    var clamped = end;
    if (clamped > duration) clamped = duration;
    final minEnd = last.start + minTrimDuration;
    if (clamped < minEnd) clamped = minEnd;
    if (clamped <= last.start) return;
    segments[segments.length - 1] = last.copyWith(end: clamped);
  }

  void touch() => updatedAt = DateTime.now();

  VideoProject copyWith({
    List<ClipSegment>? segments,
    List<TextOverlay>? overlays,
    List<ProjectMusic>? musicTracks,
    ExportPreset? preset,
    double? rotation,
    DateTime? updatedAt,
  }) {
    return VideoProject(
      id: id,
      sourcePath: sourcePath,
      duration: duration,
      segments: segments ?? this.segments.map((s) => s.copyWith()).toList(),
      overlays: overlays ?? List<TextOverlay>.from(this.overlays),
      musicTracks: musicTracks ??
          this.musicTracks.map((m) => m.copyWith()).toList(),
      preset: preset ?? this.preset,
      rotation: rotation ?? this.rotation,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': kProjectFileVersion,
    'id': id,
    'updatedAt': updatedAt.toIso8601String(),
    'sourceFileName': sourceFileName,
    'durationMs': duration.inMilliseconds,
    'trim': trim.toJson(),
    'segments': segments.map((segment) => segment.toJson()).toList(),
    'rotation': rotation,
    'preset': preset.name,
    'overlays': overlays.map((overlay) => overlay.toJson()).toList(),
    'musicTracks': musicTracks.map((m) => m.toJson()).toList(),
  };

  factory VideoProject.fromJson(
    Map<String, dynamic> json, {
    required String sourcePath,
  }) {
    final duration = Duration(milliseconds: json['durationMs'] as int);
    final segmentJson = json['segments'] as List<dynamic>?;
    final segments = segmentJson == null
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

    final resolvedSegments = normalizeSegments(
      segments.isEmpty
          ? segmentsFromTrim(start: Duration.zero, end: duration)
          : segments,
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

    return VideoProject(
      id: json['id'] as String,
      sourcePath: sourcePath,
      duration: duration,
      segments: resolvedSegments,
      overlays: (json['overlays'] as List<dynamic>)
          .map((entry) => TextOverlay.fromJson(entry as Map<String, dynamic>))
          .toList(),
      musicTracks: musicTracks,
      preset: ExportPreset.values.byName(json['preset'] as String),
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }
}
