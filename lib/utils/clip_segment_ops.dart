import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/utils/duration_format.dart';
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
  final left = segment.copyWith(
    end: point,
    fadeOut: Duration.zero,
    clearTransition: true,
  );
  final right = ClipSegment(
    start: point,
    end: segment.end,
    volume: segment.volume,
    fadeIn: Duration.zero,
    fadeOut: segment.fadeOut,
    transitionId: segment.transitionId,
    transitionDuration: segment.transitionDuration,
  );
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

/// Earliest source time [segment] may start — previous neighbor's end, or zero.
Duration segmentTrimMinStart(List<ClipSegment> segments, ClipSegment segment) {
  final index = segments.indexWhere((s) => s.id == segment.id);
  if (index <= 0) return Duration.zero;
  return segments[index - 1].end;
}

/// Latest source time [segment] may end — next neighbor's start, or [sourceDuration].
Duration segmentTrimMaxEnd(
  List<ClipSegment> segments,
  ClipSegment segment, {
  required Duration sourceDuration,
}) {
  final index = segments.indexWhere((s) => s.id == segment.id);
  if (index < 0) return sourceDuration;
  if (index >= segments.length - 1) return sourceDuration;
  return segments[index + 1].start;
}

/// Trims [segment] start in place; packed timeline ripples followers automatically.
ClipSegment? trimSegmentStart(
  List<ClipSegment> segments,
  ClipSegment segment, {
  required Duration nextStart,
  required Duration sourceDuration,
}) {
  final minStart = segmentTrimMinStart(segments, segment);
  final maxStart = segment.end - minTrimDuration;
  if (maxStart < minStart) return null;
  final clamped = clampDuration(nextStart, minStart, maxStart);
  if (clamped == segment.start) return segment;
  return segment.copyWith(start: clamped);
}

/// Trims [segment] end; packed timeline ripples followers automatically.
ClipSegment? trimSegmentEnd(
  List<ClipSegment> segments,
  ClipSegment segment, {
  required Duration nextEnd,
  required Duration sourceDuration,
}) {
  final minEnd = segment.start + minTrimDuration;
  final maxEnd = segmentTrimMaxEnd(
    segments,
    segment,
    sourceDuration: sourceDuration,
  );
  if (maxEnd < minEnd) return null;
  final clamped = clampDuration(nextEnd, minEnd, maxEnd);
  if (clamped == segment.end) return segment;
  return segment.copyWith(end: clamped);
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

/// Sum of transition overlaps that shorten the exported timeline.
Duration totalTransitionOverlap(List<ClipSegment> segments) {
  if (segments.length < 2) return Duration.zero;
  var ms = 0;
  for (var i = 0; i < segments.length - 1; i++) {
    final segment = segments[i];
    if (!segment.hasTransition) continue;
    ms += clampedTransitionDuration(
      segment,
      next: segments[i + 1],
    ).inMilliseconds;
  }
  return Duration(milliseconds: ms);
}

/// Export length after xfade overlaps are subtracted.
Duration exportTimelineDuration(List<ClipSegment> segments) {
  final kept = totalKeptDuration(segments);
  final overlap = totalTransitionOverlap(segments);
  final ms = kept.inMilliseconds - overlap.inMilliseconds;
  return Duration(milliseconds: ms < 0 ? 0 : ms);
}

/// xfade duration must fit inside both adjacent segments.
Duration clampedTransitionDuration(
  ClipSegment segment, {
  required ClipSegment next,
}) {
  if (!segment.hasTransition) return Duration.zero;
  final requested = segment.transitionDuration.inMilliseconds;
  if (requested <= 0) return Duration.zero;
  final maxMs = [
    segment.duration.inMilliseconds,
    next.duration.inMilliseconds,
  ].reduce((a, b) => a < b ? a : b);
  // Leave a tiny pad only when the transition would nearly empty a side.
  final limit = maxMs > 100 ? maxMs - 50 : maxMs;
  if (limit <= 0) return Duration.zero;
  final safe = requested > limit ? limit : requested;
  return Duration(milliseconds: safe);
}

/// Packed-timeline time of the cut **after** [afterIndex] (0..n-2).
Duration cutExportTimeAfter(List<ClipSegment> segments, int afterIndex) {
  var offset = Duration.zero;
  for (var i = 0; i <= afterIndex && i < segments.length; i++) {
    offset += segments[i].duration;
  }
  return offset;
}

/// Sequence-time span of a cut transition, centered on the cut.
({Duration start, Duration end})? transitionSequenceSpan(
  List<ClipSegment> segments,
  int afterIndex,
) {
  if (afterIndex < 0 || afterIndex >= segments.length - 1) return null;
  final segment = segments[afterIndex];
  final next = segments[afterIndex + 1];
  final td = clampedTransitionDuration(segment, next: next);
  if (td <= Duration.zero) return null;

  final cut = cutExportTimeAfter(segments, afterIndex);
  final halfMs = td.inMilliseconds ~/ 2;
  var startMs = cut.inMilliseconds - halfMs;
  var endMs = startMs + td.inMilliseconds;
  final totalMs = totalKeptDuration(segments).inMilliseconds;
  if (startMs < 0) {
    endMs -= startMs;
    startMs = 0;
  }
  if (endMs > totalMs) {
    startMs -= endMs - totalMs;
    endMs = totalMs;
    if (startMs < 0) startMs = 0;
  }
  if (endMs <= startMs) return null;
  return (
    start: Duration(milliseconds: startMs),
    end: Duration(milliseconds: endMs),
  );
}

/// Index of the cut (after segment i) nearest to [sequenceTime], or -1.
int nearestCutIndex(List<ClipSegment> segments, Duration sequenceTime) {
  if (segments.length < 2) return -1;
  var bestIndex = 0;
  var bestDist = 1 << 62;
  for (var i = 0; i < segments.length - 1; i++) {
    final cutAt = cutExportTimeAfter(segments, i);
    final dist = (cutAt - sequenceTime).inMilliseconds.abs();
    if (dist < bestDist) {
      bestDist = dist;
      bestIndex = i;
    }
  }
  return bestIndex;
}

bool hasVideoCuts(List<ClipSegment> segments) => segments.length > 1;

Duration? sourceTimeToExportTime(
  List<ClipSegment> segments,
  Duration sourceTime, {
  bool applyTransitions = false,
}) {
  var offset = Duration.zero;
  for (var i = 0; i < segments.length; i++) {
    final segment = segments[i];
    if (sourceTime < segment.start) return null;
    if (sourceTime < segment.end) {
      return offset + (sourceTime - segment.start);
    }
    if (sourceTime == segment.end) {
      return offset + segment.duration;
    }
    offset += segment.duration;
    if (applyTransitions &&
        i < segments.length - 1 &&
        segment.hasTransition) {
      offset -= clampedTransitionDuration(segment, next: segments[i + 1]);
    }
  }
  return null;
}

/// Maps edited timeline position back to source time.
Duration exportTimeToSourceTime(
  List<ClipSegment> segments,
  Duration exportTime, {
  bool applyTransitions = false,
}) {
  if (segments.isEmpty) return Duration.zero;
  if (exportTime <= Duration.zero) return segments.first.start;

  var offset = Duration.zero;
  for (var i = 0; i < segments.length; i++) {
    final segment = segments[i];
    final nextOffset = offset + segment.duration;
    if (exportTime < nextOffset) {
      return segment.start + (exportTime - offset);
    }
    offset = nextOffset;
    if (applyTransitions &&
        i < segments.length - 1 &&
        segment.hasTransition) {
      offset -= clampedTransitionDuration(segment, next: segments[i + 1]);
    }
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

/// Maps an overlay end (exclusive) to an exclusive export-timeline position.
Duration? overlayExportTimeForEnd(
  List<ClipSegment> segments,
  Duration sourceEnd,
) {
  final probeMs = sourceEnd.inMilliseconds - 1;
  if (probeMs >= 0) {
    final mapped = sourceTimeToExportTime(
      segments,
      Duration(milliseconds: probeMs),
    );
    if (mapped != null) {
      return Duration(milliseconds: mapped.inMilliseconds + 1);
    }
  }
  final atEnd = sourceTimeToExportTime(segments, sourceEnd);
  if (atEnd != null) {
    return Duration(milliseconds: atEnd.inMilliseconds + 1);
  }
  return null;
}

/// Export-timeline span for painting handles and dragging an overlay layer.
({Duration start, Duration end})? overlayTimelineSpan(
  TextOverlay overlay,
  List<ClipSegment> segments,
) {
  final ranges = overlayKeptRanges(overlay, segments);
  if (ranges.isEmpty) return null;

  var exportStart = sourceTimeToExportTime(segments, overlay.start);
  var exportEnd = overlayExportTimeForEnd(segments, overlay.end);

  exportStart ??= sourceTimeToExportTime(segments, ranges.first.start);
  exportEnd ??= overlayExportTimeForEnd(segments, ranges.last.end);
  if (exportStart == null || exportEnd == null) return null;

  if (exportEnd <= exportStart) {
    exportEnd = Duration(milliseconds: exportStart.inMilliseconds + 1);
  }
  return (start: exportStart, end: exportEnd);
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
      exportTimelineDuration(segments).inMilliseconds / 1000.0;
  final spans = <({double start, double end})>[];

  for (final range in overlayKeptRanges(overlay, segments)) {
    final exportStart = sourceTimeToExportTime(
      segments,
      range.start,
      applyTransitions: true,
    );
    if (exportStart == null) continue;

    final probeMs = range.end.inMilliseconds - 1;
    Duration? exportEnd;
    if (probeMs >= range.start.inMilliseconds) {
      exportEnd = sourceTimeToExportTime(
        segments,
        Duration(milliseconds: probeMs),
        applyTransitions: true,
      );
    }
    exportEnd ??= sourceTimeToExportTime(
      segments,
      range.end,
      applyTransitions: true,
    );
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
