import 'dart:math' as math;

import 'package:uuid/uuid.dart';

/// One music clip on the timeline (CapCut-style audio track block).
class ProjectMusic {
  ProjectMusic({
    String? id,
    required this.title,
    this.artist,
    required this.fileName,
    this.fileDuration,
    Duration? clipDuration,
    this.timelineStart = Duration.zero,
    this.sourceOffset = Duration.zero,
    this.volume = 0.85,
    this.fadeIn = Duration.zero,
    this.fadeOut = Duration.zero,
    this.licenseUrl,
    this.source = MusicSource.local,
    this.externalId,
    this.lane = 0,
  })  : id = id ?? const Uuid().v4(),
        clipDuration = clipDuration ??
            _defaultClipDuration(fileDuration, sourceOffset);

  final String id;
  final String title;
  final String? artist;

  /// Basename of the audio file inside the project folder.
  final String fileName;

  /// Full length of the audio file when known.
  final Duration? fileDuration;

  /// How long this clip plays on the timeline.
  final Duration clipDuration;

  final Duration timelineStart;
  final Duration sourceOffset;
  final double volume;
  final Duration fadeIn;
  final Duration fadeOut;
  final String? licenseUrl;
  final MusicSource source;
  final String? externalId;

  /// Vertical music lane index (0 = top). Overlapping clips go to new lanes.
  final int lane;

  Duration get timelineEnd => timelineStart + clipDuration;

  bool containsSourceTime(Duration t) =>
      t >= timelineStart && t < timelineEnd;

  /// Fades may span almost the whole clip; they only leave a tiny gap between.
  Duration get effectiveFadeIn {
    final resolved = resolvedFades;
    return resolved.$1;
  }

  Duration get effectiveFadeOut {
    final resolved = resolvedFades;
    return resolved.$2;
  }

  /// `(fadeIn, fadeOut)` clamped so they never overlap beyond [minMusicFadeGap].
  (Duration, Duration) get resolvedFades {
    var fi = fadeIn.isNegative ? Duration.zero : fadeIn;
    var fo = fadeOut.isNegative ? Duration.zero : fadeOut;
    final budgetMs =
        clipDuration.inMilliseconds - minMusicFadeGap.inMilliseconds;
    if (budgetMs <= 0) return (Duration.zero, Duration.zero);

    var fiMs = fi.inMilliseconds;
    var foMs = fo.inMilliseconds;
    if (fiMs < 0) fiMs = 0;
    if (foMs < 0) foMs = 0;

    if (fiMs + foMs > budgetMs) {
      final total = fiMs + foMs;
      fiMs = ((fiMs / total) * budgetMs).round();
      foMs = budgetMs - fiMs;
    }
    return (Duration(milliseconds: fiMs), Duration(milliseconds: foMs));
  }

  /// Max fade-in while keeping current fade-out.
  Duration get maxFadeIn {
    final fo = fadeOut.isNegative ? Duration.zero : fadeOut;
    final foMs = fo.inMilliseconds.clamp(0, clipDuration.inMilliseconds);
    final maxMs =
        clipDuration.inMilliseconds - foMs - minMusicFadeGap.inMilliseconds;
    if (maxMs <= 0) return Duration.zero;
    return Duration(milliseconds: maxMs);
  }

  /// Max fade-out while keeping current fade-in.
  Duration get maxFadeOut {
    final fi = fadeIn.isNegative ? Duration.zero : fadeIn;
    final fiMs = fi.inMilliseconds.clamp(0, clipDuration.inMilliseconds);
    final maxMs =
        clipDuration.inMilliseconds - fiMs - minMusicFadeGap.inMilliseconds;
    if (maxMs <= 0) return Duration.zero;
    return Duration(milliseconds: maxMs);
  }

  /// Playback volume at [localOffset] into the clip (0 → clipDuration).
  /// Fade ramps use a half-cosine curve so the envelope reads as a round cover.
  double volumeAt(Duration localOffset) {
    final base = volume.clamp(0.0, 1.0);
    final t = localOffset.inMilliseconds.toDouble();
    final dur = clipDuration.inMilliseconds.toDouble();
    if (dur <= 0) return 0;
    final fades = resolvedFades;
    final fi = fades.$1.inMilliseconds.toDouble();
    final fo = fades.$2.inMilliseconds.toDouble();

    var gain = 1.0;
    if (fi > 0 && t < fi) {
      gain = _roundFadeGain(t / fi);
    }
    if (fo > 0 && t > dur - fo) {
      final outGain = _roundFadeGain((dur - t) / fo);
      gain = gain < outGain ? gain : outGain;
    }
    return base * gain;
  }

  /// Smooth 0→1 ease (half-cosine) for rounded fade covers.
  static double _roundFadeGain(double linear01) {
    final t = linear01.clamp(0.0, 1.0);
    return 0.5 - 0.5 * math.cos(math.pi * t);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    if (artist != null) 'artist': artist,
    'fileName': fileName,
    if (fileDuration != null) 'durationMs': fileDuration!.inMilliseconds,
    'clipDurationMs': clipDuration.inMilliseconds,
    'timelineStartMs': timelineStart.inMilliseconds,
    'sourceOffsetMs': sourceOffset.inMilliseconds,
    'volume': volume,
    'fadeInMs': fadeIn.inMilliseconds,
    'fadeOutMs': fadeOut.inMilliseconds,
    if (licenseUrl != null) 'licenseUrl': licenseUrl,
    'source': source.name,
    if (externalId != null) 'externalId': externalId,
    'lane': lane,
  };

  factory ProjectMusic.fromJson(Map<String, dynamic> json) {
    final fileDuration = json['durationMs'] == null && json['fileDurationMs'] == null
        ? null
        : Duration(
            milliseconds: (json['fileDurationMs'] as int?) ??
                (json['durationMs'] as int? ?? 0),
          );
    final clipMs = json['clipDurationMs'] as int?;
    return ProjectMusic(
      id: json['id'] as String? ?? const Uuid().v4(),
      title: json['title'] as String,
      artist: json['artist'] as String?,
      fileName: json['fileName'] as String,
      fileDuration: fileDuration,
      clipDuration: clipMs == null ? null : Duration(milliseconds: clipMs),
      timelineStart: Duration(milliseconds: json['timelineStartMs'] as int? ?? 0),
      sourceOffset: Duration(milliseconds: json['sourceOffsetMs'] as int? ?? 0),
      volume: (json['volume'] as num?)?.toDouble() ?? 0.85,
      fadeIn: Duration(milliseconds: json['fadeInMs'] as int? ?? 0),
      fadeOut: Duration(milliseconds: json['fadeOutMs'] as int? ?? 0),
      licenseUrl: json['licenseUrl'] as String?,
      source: MusicSource.values.asNameMap()[json['source'] as String? ?? 'local'] ??
          MusicSource.local,
      externalId: json['externalId'] as String?,
      lane: json['lane'] as int? ?? 0,
    );
  }

  ProjectMusic copyWith({
    String? title,
    String? artist,
    String? fileName,
    Duration? fileDuration,
    Duration? clipDuration,
    Duration? timelineStart,
    Duration? sourceOffset,
    double? volume,
    Duration? fadeIn,
    Duration? fadeOut,
    String? licenseUrl,
    MusicSource? source,
    String? externalId,
    int? lane,
    bool newId = false,
  }) {
    return ProjectMusic(
      id: newId ? const Uuid().v4() : id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      fileName: fileName ?? this.fileName,
      fileDuration: fileDuration ?? this.fileDuration,
      clipDuration: clipDuration ?? this.clipDuration,
      timelineStart: timelineStart ?? this.timelineStart,
      sourceOffset: sourceOffset ?? this.sourceOffset,
      volume: volume ?? this.volume,
      fadeIn: fadeIn ?? this.fadeIn,
      fadeOut: fadeOut ?? this.fadeOut,
      licenseUrl: licenseUrl ?? this.licenseUrl,
      source: source ?? this.source,
      externalId: externalId ?? this.externalId,
      lane: lane ?? this.lane,
    );
  }

  static Duration _defaultClipDuration(
    Duration? fileDuration,
    Duration sourceOffset,
  ) {
    if (fileDuration == null) return const Duration(seconds: 30);
    final available = fileDuration - sourceOffset;
    if (available <= Duration.zero) return const Duration(seconds: 1);
    return available;
  }
}

enum MusicSource { local, jamendo, pixabay, mixkit }

/// Minimum length of a music clip after trim/split.
const minMusicClipDuration = Duration(milliseconds: 500);

/// Small gap kept between fade-in end and fade-out start.
const minMusicFadeGap = Duration(milliseconds: 80);

/// Legacy slider ceiling (inspector removed); fades may use the full clip.
const maxMusicFade = Duration(seconds: 5);

/// Split [clip] at [at] (source timeline). Returns null if too close to edges.
(ProjectMusic left, ProjectMusic right)? splitMusicClip(
  ProjectMusic clip,
  Duration at,
) {
  if (at <= clip.timelineStart + minMusicClipDuration) return null;
  if (at >= clip.timelineEnd - minMusicClipDuration) return null;

  final leftDur = at - clip.timelineStart;
  final rightDur = clip.timelineEnd - at;
  final intoSource = at - clip.timelineStart;

  final left = clip.copyWith(
    clipDuration: leftDur,
    fadeOut: Duration.zero,
  );
  final right = clip.copyWith(
    newId: true,
    timelineStart: at,
    sourceOffset: clip.sourceOffset + intoSource,
    clipDuration: rightDur,
    fadeIn: Duration.zero,
    lane: clip.lane,
  );
  return (left, right);
}

bool musicRangesOverlap(ProjectMusic a, ProjectMusic b) {
  return a.timelineStart < b.timelineEnd && b.timelineStart < a.timelineEnd;
}

/// Assigns a music lane for [clip].
///
/// When [preferLowestLane] is true (default — CapCut-style), packs onto the
/// lowest free lane for [clip]'s time range so a split piece dragged into a
/// gap can move back up. Only then opens a new lane.
///
/// When false, keeps [clip.lane] when free; on conflict prefers below, then above.
ProjectMusic assignMusicLane(
  List<ProjectMusic> tracks,
  ProjectMusic clip, {
  bool preferLowestLane = true,
}) {
  final others = tracks.where((m) => m.id != clip.id);
  bool fits(int lane) {
    for (final other in others) {
      if (other.lane != lane) continue;
      if (musicRangesOverlap(other, clip)) return false;
    }
    return true;
  }

  final maxExisting =
      others.fold<int>(-1, (m, t) => t.lane > m ? t.lane : m);

  if (preferLowestLane) {
    for (var lane = 0; lane <= maxExisting; lane++) {
      if (fits(lane)) return clip.copyWith(lane: lane);
    }
    return clip.copyWith(lane: maxExisting + 1);
  }

  if (fits(clip.lane)) return clip;

  // Search nearest free lane above and below the requested one.
  for (var dist = 1; dist <= maxExisting + 1; dist++) {
    final up = clip.lane - dist;
    final down = clip.lane + dist;
    if (up >= 0 && fits(up)) return clip.copyWith(lane: up);
    if (down <= maxExisting + 1 && fits(down)) {
      return clip.copyWith(lane: down);
    }
  }
  return clip.copyWith(lane: maxExisting + 1);
}

/// Removes empty lane gaps after moves/deletes (0..n contiguous).
List<ProjectMusic> compactMusicLanes(List<ProjectMusic> tracks) {
  if (tracks.isEmpty) return tracks;
  final used = tracks.map((t) => t.lane).toSet().toList()..sort();
  final remap = <int, int>{
    for (var i = 0; i < used.length; i++) used[i]: i,
  };
  return [
    for (final track in tracks)
      remap[track.lane] == track.lane
          ? track
          : track.copyWith(lane: remap[track.lane]!),
  ];
}

int musicLaneCount(List<ProjectMusic> tracks) {
  if (tracks.isEmpty) return 0;
  var maxLane = 0;
  for (final track in tracks) {
    if (track.lane > maxLane) maxLane = track.lane;
  }
  return maxLane + 1;
}

ProjectMusic? musicClipAtTime(List<ProjectMusic> tracks, Duration sourceTime) {
  ProjectMusic? best;
  for (final track in tracks) {
    if (!track.containsSourceTime(sourceTime)) continue;
    if (best == null || track.lane >= best.lane) best = track;
  }
  return best;
}
