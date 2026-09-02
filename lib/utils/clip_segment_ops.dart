import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/utils/timeline_math.dart';

List<ClipSegment> segmentsFromTrim({
  required Duration start,
  required Duration end,
}) {
  return [ClipSegment(start: start, end: end)];
}

List<ClipSegment> splitSegmentsAt(
  List<ClipSegment> segments,
  Duration at,
) {
  final point = resolveSplitPoint(segments, at);
  final index = segments.indexWhere((s) => s.start < point && point < s.end);
  if (index == -1) {
    throw StateError('split_out_of_range');
  }

  final segment = segments[index];
  final left = segment.copyWith(end: point);
  final right = ClipSegment(start: point, end: segment.end);
  return [
    ...segments.sublist(0, index),
    left,
    right,
    ...segments.sublist(index + 1),
  ];
}

/// Picks a legal split time near [at], nudging off segment edges when needed.
Duration resolveSplitPoint(List<ClipSegment> segments, Duration at) {
  ClipSegment? segment;
  var point = at;

  for (final candidate in segments) {
    if (candidate.start < point && point < candidate.end) {
      segment = candidate;
      break;
    }
  }

  if (segment == null) {
    for (final candidate in segments) {
      if (candidate.start == point && point < candidate.end) {
        segment = candidate;
        point = point + const Duration(milliseconds: 1);
        break;
      }
    }
  }

  if (segment == null) {
    throw StateError('split_out_of_range');
  }

  final minPoint = segment.start + minSplitPartDuration;
  final maxPoint = segment.end - minSplitPartDuration;
  if (minPoint > maxPoint) {
    throw StateError('split_too_short');
  }

  if (point < minPoint) return minPoint;
  if (point > maxPoint) return maxPoint;
  return point;
}

/// Merges accidental sub-frame splinters created by repeated boundary splits.
List<ClipSegment> collapseMicroSegments(List<ClipSegment> segments) {
  final valid = segments.where((segment) => segment.end > segment.start).toList();
  if (valid.length <= 1) return valid;

  final merged = <ClipSegment>[valid.first];
  for (var i = 1; i < valid.length; i++) {
    final segment = valid[i];
    if (segment.duration < minSplitPartDuration) {
      merged[merged.length - 1] = merged.last.copyWith(end: segment.end);
    } else {
      merged.add(segment);
    }
  }
  return merged;
}

/// Normalizes segment lists for editing, playback, and export.
List<ClipSegment> normalizeSegments(
  List<ClipSegment> segments, {
  required Duration sourceDuration,
}) {
  return collapseMicroSegments(
    repairSegments(segments, sourceDuration: sourceDuration),
  );
}

/// Drops invalid segments and clamps bounds to the source file duration.
List<ClipSegment> repairSegments(
  List<ClipSegment> segments, {
  required Duration sourceDuration,
}) {
  if (segments.isEmpty) {
    return segmentsFromTrim(start: Duration.zero, end: sourceDuration);
  }

  final valid = <ClipSegment>[];
  for (final segment in segments) {
    var start = segment.start;
    var end = segment.end;
    if (start < Duration.zero) start = Duration.zero;
    if (end > sourceDuration) end = sourceDuration;
    if (end <= start) continue;
    valid.add(segment.copyWith(start: start, end: end));
  }

  valid.sort((a, b) => a.start.compareTo(b.start));

  if (valid.isEmpty) {
    return segmentsFromTrim(start: Duration.zero, end: sourceDuration);
  }
  return valid;
}

/// Maps the packed timeline position under the centre playhead to source time.
Duration splitSourceFromSequence(
  List<ClipSegment> segments,
  Duration sequenceTime,
) {
  if (segments.isEmpty) return Duration.zero;

  final clamped = sequenceTime < Duration.zero
      ? Duration.zero
      : sequenceTime > totalKeptDuration(segments)
          ? totalKeptDuration(segments)
          : sequenceTime;

  // Stay inside the segment the user sees, not a 1 ms tail on the next block.
  var probe = clamped;
  if (probe > Duration.zero) {
    probe -= const Duration(milliseconds: 1);
  }
  return exportTimeToSourceTime(segments, probe);
}

bool isAlreadySplitAt(List<ClipSegment> segments, Duration point) {
  for (var i = 1; i < segments.length; i++) {
    if (segments[i].start == point && segments[i - 1].end == point) {
      return true;
    }
  }
  return false;
}

List<ClipSegment> deleteSegment(
  List<ClipSegment> segments,
  String segmentId,
) {
  if (segments.length <= 1) {
    throw StateError('cannot_delete_last_segment');
  }
  final next = segments.where((s) => s.id != segmentId).toList(growable: false);
  if (next.isEmpty) {
    throw StateError('cannot_delete_last_segment');
  }
  for (final segment in next) {
    if (segment.duration < minTrimDuration) {
      throw StateError('segment_too_short');
    }
  }
  return next;
}

ClipSegment? segmentAt(
  List<ClipSegment> segments,
  Duration time, {
  bool inclusiveEnd = false,
}) {
  for (final segment in segments) {
    final inside = inclusiveEnd
        ? time >= segment.start && time <= segment.end
        : time >= segment.start && time < segment.end;
    if (inside) return segment;
  }
  return null;
}

bool isInKeptRegion(List<ClipSegment> segments, Duration time) {
  return segmentAt(segments, time) != null;
}

Duration? nextSegmentStartAfter(
  List<ClipSegment> segments,
  Duration time,
) {
  for (final segment in segments) {
    if (segment.start > time) return segment.start;
  }
  return null;
}

ClipSegment? segmentEndingAtOrBefore(
  List<ClipSegment> segments,
  Duration time,
) {
  ClipSegment? best;
  for (final segment in segments) {
    if (segment.end <= time) {
      if (best == null || segment.end > best.end) best = segment;
    }
  }
  return best;
}

Duration totalKeptDuration(List<ClipSegment> segments) {
  return Duration(
    milliseconds: segments
        .map((segment) => segment.duration.inMilliseconds)
        .fold<int>(0, (sum, ms) => sum + ms),
  );
}

Duration? sourceTimeToExportTime(
  List<ClipSegment> segments,
  Duration sourceTime,
) {
  var offset = Duration.zero;
  for (final segment in segments) {
    if (sourceTime < segment.start) return null;
    if (sourceTime < segment.end) {
      return offset + (sourceTime - segment.start);
    }
    if (sourceTime == segment.end) {
      return offset + segment.duration;
    }
    offset += segment.duration;
  }
  return null;
}

/// Maps edited timeline position back to source time.
Duration exportTimeToSourceTime(
  List<ClipSegment> segments,
  Duration exportTime,
) {
  if (segments.isEmpty) return Duration.zero;
  if (exportTime <= Duration.zero) return segments.first.start;

  var offset = Duration.zero;
  for (final segment in segments) {
    final nextOffset = offset + segment.duration;
    if (exportTime < nextOffset) {
      return segment.start + (exportTime - offset);
    }
    offset = nextOffset;
  }
  return segments.last.end;
}

ClipSegment? segmentAtExportTime(
  List<ClipSegment> segments,
  Duration exportTime,
) {
  if (segments.isEmpty) return null;

  var offset = Duration.zero;
  for (final segment in segments) {
    if (exportTime < offset + segment.duration) {
      return segment;
    }
    offset += segment.duration;
  }
  return segments.last;
}

/// Playhead position on the packed edited timeline.
Duration timelinePlayheadFromSource(
  List<ClipSegment> segments,
  Duration sourceTime,
) {
  final export = sourceTimeToExportTime(segments, sourceTime);
  if (export != null) return export;

  final next = nextSegmentStartAfter(segments, sourceTime);
  if (next != null) {
    return sourceTimeToExportTime(segments, next) ?? Duration.zero;
  }

  final previous = segmentEndingAtOrBefore(segments, sourceTime);
  if (previous != null) {
    final probe = previous.end - const Duration(microseconds: 1);
    if (probe >= previous.start) {
      final mapped = sourceTimeToExportTime(segments, probe);
      if (mapped != null) return mapped;
    }
  }

  return totalKeptDuration(segments);
}

/// Export-time bounds for painting a source-time span on the packed timeline.
({Duration start, Duration end})? sourceRangeToExportRange(
  List<ClipSegment> segments,
  Duration rangeStart,
  Duration rangeEnd,
) {
  final exportStart = sourceTimeToExportTime(segments, rangeStart);
  if (exportStart == null) return null;

  final probeMs = rangeEnd.inMilliseconds - 1;
  Duration? exportEnd;
  if (probeMs >= rangeStart.inMilliseconds) {
    exportEnd = sourceTimeToExportTime(
      segments,
      Duration(milliseconds: probeMs),
    );
  }
  exportEnd ??= sourceTimeToExportTime(segments, rangeEnd);
  if (exportEnd == null) return null;

  return (
    start: exportStart,
    end: Duration(milliseconds: exportEnd.inMilliseconds + 1),
  );
}

/// Kept source-time spans where [overlay] overlaps [segments].
List<({Duration start, Duration end})> overlayKeptRanges(
  TextOverlay overlay,
  List<ClipSegment> segments,
) {
  final ranges = <({Duration start, Duration end})>[];
  for (final segment in segments) {
    if (segment.end <= overlay.start || segment.start >= overlay.end) {
      continue;
    }
    final start =
        overlay.start > segment.start ? overlay.start : segment.start;
    final end = overlay.end < segment.end ? overlay.end : segment.end;
    if (start < end) {
      ranges.add((start: start, end: end));
    }
  }
  return ranges;
}

/// Merges adjacent kept spans so split points do not break the lane bar.
List<({Duration start, Duration end})> overlayTimelineRanges(
  TextOverlay overlay,
  List<ClipSegment> segments,
) {
  final ranges = overlayKeptRanges(overlay, segments);
  if (ranges.length <= 1) return ranges;

  final merged = <({Duration start, Duration end})>[ranges.first];
  for (var i = 1; i < ranges.length; i++) {
    final previous = merged.last;
    final current = ranges[i];
    if (previous.end == current.start) {
      merged[merged.length - 1] = (start: previous.start, end: current.end);
    } else {
      merged.add(current);
    }
  }
  return merged;
}

bool isOverlayVisibleAt(
  TextOverlay overlay,
  List<ClipSegment> segments,
  Duration position,
) {
  if (!overlay.isVisibleAt(position)) return false;
  return isInKeptRegion(segments, position);
}

/// Export-time spans for FFmpeg `enable` on a single overlay layer.
List<({double start, double end})> overlayExportSpans(
  TextOverlay overlay,
  List<ClipSegment> segments,
) {
  final exportDurationSec =
      totalKeptDuration(segments).inMilliseconds / 1000.0;
  final spans = <({double start, double end})>[];

  for (final range in overlayKeptRanges(overlay, segments)) {
    final exportStart = sourceTimeToExportTime(segments, range.start);
    if (exportStart == null) continue;

    final probeMs = range.end.inMilliseconds - 1;
    Duration? exportEnd;
    if (probeMs >= range.start.inMilliseconds) {
      exportEnd = sourceTimeToExportTime(
        segments,
        Duration(milliseconds: probeMs),
      );
    }
    exportEnd ??= sourceTimeToExportTime(segments, range.end);
    if (exportEnd == null) continue;

    final startSec = exportStart.inMilliseconds / 1000.0;
    final endSec = (exportEnd.inMilliseconds + 1) / 1000.0;
    if (endSec <= startSec || startSec >= exportDurationSec) continue;

    final clampedStart = startSec.clamp(0.0, exportDurationSec);
    final clampedEnd = endSec.clamp(0.0, exportDurationSec);
    if (clampedEnd <= clampedStart) continue;
    spans.add((start: clampedStart, end: clampedEnd));
  }

  return spans;
}
