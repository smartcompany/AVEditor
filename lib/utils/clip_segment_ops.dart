import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/media_asset.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/services/transition_engine.dart';
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
  return _splitSegmentAtLocal(segments, index, point);
}

/// Splits the clip under [sequenceTime] on the packed timeline.
///
/// Use this when segments use per-asset local clocks ([ClipSegment.mediaId])
/// so overlapping local ranges cannot pick the wrong clip.
List<ClipSegment> splitSegmentsAtSequenceTime(
  List<ClipSegment> segments,
  Duration sequenceTime,
) {
  final index = segmentIndexAtSequenceTime(segments, sequenceTime);
  if (index < 0) {
    throw StateError('split_out_of_range');
  }
  final segment = segments[index];
  final local = exportTimeToSourceTime(segments, sequenceTime);
  final point = resolveSplitPoint([segment], local);
  return _splitSegmentAtLocal(segments, index, point);
}

/// Index of the clip covering [sequenceTime] on the packed timeline, or -1.
int segmentIndexAtSequenceTime(
  List<ClipSegment> segments,
  Duration sequenceTime,
) {
  if (segments.isEmpty) return -1;
  var offset = Duration.zero;
  for (var i = 0; i < segments.length; i++) {
    final next = offset + segments[i].duration;
    if (segments[i].duration > Duration.zero &&
        sequenceTime >= offset &&
        sequenceTime < next) {
      return i;
    }
    offset = next;
  }
  return -1;
}

List<ClipSegment> _splitSegmentAtLocal(
  List<ClipSegment> segments,
  int index,
  Duration point,
) {
  final segment = segments[index];
  if (point <= segment.start || point >= segment.end) {
    throw StateError('split_out_of_range');
  }
  final left = segment.copyWith(
    end: point,
    fadeOut: Duration.zero,
    clearTransition: true,
  );
  final right = ClipSegment(
    mediaId: segment.mediaId,
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
  List<MediaAsset> mediaAssets = const [],
  Duration? sourceDuration,
}) {
  return collapseMicroSegments(
    repairSegments(
      segments,
      mediaAssets: mediaAssets,
      sourceDuration: sourceDuration,
    ),
  );
}

MediaAsset? _assetFor(
  List<MediaAsset> mediaAssets,
  ClipSegment segment,
) {
  final id = segment.mediaId;
  if (id == null) return null;
  for (final asset in mediaAssets) {
    if (asset.id == id) return asset;
  }
  return null;
}

/// Drops invalid segments and clamps bounds per media asset.
///
/// Preserves list order so drag-reorder of cut clips is not undone.
List<ClipSegment> repairSegments(
  List<ClipSegment> segments, {
  List<MediaAsset> mediaAssets = const [],
  Duration? sourceDuration,
}) {
  final fallback = sourceDuration ?? Duration.zero;
  if (segments.isEmpty) {
    return segmentsFromTrim(start: Duration.zero, end: fallback);
  }

  final valid = <ClipSegment>[];
  for (final segment in segments) {
    var start = segment.start;
    var end = segment.end;
    if (start < Duration.zero) start = Duration.zero;
    final asset = _assetFor(mediaAssets, segment);
    final maxEnd = asset?.maxClipEnd ??
        (fallback > Duration.zero ? fallback : const Duration(hours: 12));
    if (end > maxEnd) end = maxEnd;
    if (end <= start) continue;
    valid.add(segment.copyWith(start: start, end: end));
  }

  if (valid.isEmpty) {
    return segmentsFromTrim(start: Duration.zero, end: fallback);
  }
  return valid;
}

/// Swaps [leftIndex] with the next clip. List order is playback order.
List<ClipSegment> swapAdjacentSegments(
  List<ClipSegment> segments,
  int leftIndex,
) {
  if (leftIndex < 0 || leftIndex >= segments.length - 1) {
    return List<ClipSegment>.from(segments);
  }
  final next = List<ClipSegment>.from(segments);
  final left = next[leftIndex];
  final right = next[leftIndex + 1];
  next[leftIndex] = right;
  next[leftIndex + 1] = left;
  return next;
}

/// Moves the clip at [fromIndex] to [insertIndex] (0 = before first, length =
/// after last). No-op when the slot is the clip's current home.
List<ClipSegment> moveSegmentToIndex(
  List<ClipSegment> segments,
  int fromIndex,
  int insertIndex,
) {
  if (fromIndex < 0 || fromIndex >= segments.length) {
    return List<ClipSegment>.from(segments);
  }
  if (insertIndex < 0 || insertIndex > segments.length) {
    return List<ClipSegment>.from(segments);
  }
  if (insertIndex == fromIndex || insertIndex == fromIndex + 1) {
    return List<ClipSegment>.from(segments);
  }
  final next = List<ClipSegment>.from(segments);
  final item = next.removeAt(fromIndex);
  var dest = insertIndex;
  if (insertIndex > fromIndex) dest = insertIndex - 1;
  dest = dest.clamp(0, next.length);
  next.insert(dest, item);
  return next;
}

/// True when dropping at [insertIndex] would change order for [fromIndex].
bool segmentReorderWouldMove(int fromIndex, int insertIndex) {
  return insertIndex != fromIndex && insertIndex != fromIndex + 1;
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

/// Earliest in-point on the clip's own media (multi-source: always zero).
Duration segmentTrimMinStart(List<ClipSegment> segments, ClipSegment segment) {
  return Duration.zero;
}

/// Latest out-point on the clip's own media (asset duration or image hold max).
Duration segmentTrimMaxEnd(
  List<ClipSegment> segments,
  ClipSegment segment, {
  MediaAsset? asset,
  Duration? sourceDuration,
}) {
  if (asset != null) return asset.maxClipEnd;
  if (sourceDuration != null && sourceDuration > Duration.zero) {
    return sourceDuration;
  }
  return kMaxImageHoldDuration;
}

/// Trims [segment] start; packed timeline ripples followers automatically.
/// Image clips keep start at zero (hold length changes via the right edge).
ClipSegment? trimSegmentStart(
  List<ClipSegment> segments,
  ClipSegment segment, {
  required Duration nextStart,
  MediaAsset? asset,
  Duration? sourceDuration,
}) {
  if (asset != null && asset.isImage) return segment;
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
  MediaAsset? asset,
  Duration? sourceDuration,
}) {
  final minEnd = segment.start + minTrimDuration;
  final maxEnd = segmentTrimMaxEnd(
    segments,
    segment,
    asset: asset,
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
  for (var i = 0; i < segments.length; i++) {
    final segment = segments[i];
    if (time >= segment.start && time < segment.end) {
      if (i + 1 >= segments.length) return null;
      return segments[i + 1].start;
    }
  }
  Duration? best;
  for (final segment in segments) {
    if (segment.start <= time) continue;
    if (best == null || segment.start < best) best = segment.start;
  }
  return best;
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

/// Sum of transition durations (informational; does not shorten the timeline).
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

/// Export / packed timeline length.
///
/// Duration-preserving: total stays [totalKeptDuration] (hard-cut length).
/// Transitions are centered on the cut and sample A-end + B-start via handles.
Duration exportTimelineDuration(List<ClipSegment> segments) {
  return totalKeptDuration(segments);
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

/// Floor(td/2) before the cut; td − floor(td/2) after (odd td safe).
({int before, int after}) transitionHalfMs(Duration td) {
  final ms = td.inMilliseconds;
  if (ms <= 0) return (before: 0, after: 0);
  final before = ms ~/ 2;
  return (before: before, after: ms - before);
}

/// Dual-player transition window on the **source** timeline.
///
/// Duration-preserving, centered on the cut:
/// `[outgoing.end − ⌊td/2⌋, outgoing.end + ⌈td/2⌉)`.
/// Main shows A[end−before, end] (via playhead); aux shows B[start, start+after]
/// stretched over the window — **different** frames so dissolve is visible.
class PreviewFadeWindow {
  const PreviewFadeWindow({
    required this.afterIndex,
    required this.t,
    required this.outgoing,
    required this.incoming,
    required this.td,
  });

  final int afterIndex;
  final double t;
  final ClipSegment outgoing;
  final ClipSegment incoming;
  final Duration td;

  Duration get windowStart {
    final half = transitionHalfMs(td);
    return outgoing.end - Duration(milliseconds: half.before);
  }

  Duration get windowEnd {
    final half = transitionHalfMs(td);
    return outgoing.end + Duration(milliseconds: half.after);
  }

  /// Source time the aux player should show for this [t].
  ///
  /// B's first ⌈td/2⌉ only, mapped across the full window (matches solo B at t=1).
  Duration get auxSourceTime {
    final half = transitionHalfMs(td);
    final ms = incoming.start.inMilliseconds +
        (t * half.after).round();
    final hi = incoming.end.inMilliseconds;
    return Duration(
      milliseconds: ms.clamp(incoming.start.inMilliseconds, hi),
    );
  }

  /// Source time the outgoing (main) layer should show for this [t].
  ///
  /// A's last ⌊td/2⌋ only, mapped across the full window (no post-cut handles).
  Duration get outgoingSourceTime {
    final half = transitionHalfMs(td);
    final startMs = outgoing.end.inMilliseconds - half.before;
    final ms = startMs + (t * half.before).round();
    final lo = outgoing.start.inMilliseconds;
    final hi = outgoing.end.inMilliseconds;
    return Duration(milliseconds: ms.clamp(lo, hi));
  }
}

/// Returns the active dual-layer transition preview at [sourcePos], or null.
///
/// [sourcePos] is packed timeline time when any segment has a [mediaId]
/// (multi-source); otherwise it is the legacy master-file clock.
PreviewFadeWindow? previewFadeAt(
  List<ClipSegment> segments,
  Duration sourcePos,
) {
  if (segments.length < 2) return null;
  final posMs = sourcePos.inMilliseconds;
  final packedClock = segments.any((s) => s.mediaId != null);
  final engine = TransitionEngine.instance;
  for (var i = 0; i < segments.length - 1; i++) {
    final outgoing = segments[i];
    final incoming = segments[i + 1];
    final plan = engine.plan(outgoing.transition);
    if (plan.previewKind != TransitionPreviewKind.dualLayer) continue;
    final td = clampedTransitionDuration(outgoing, next: incoming);
    if (td <= Duration.zero) continue;
    final half = transitionHalfMs(td);
    final cutMs = packedClock
        ? cutExportTimeAfter(segments, i).inMilliseconds
        : outgoing.end.inMilliseconds;
    final startMs = cutMs - half.before;
    final endMs = cutMs + half.after;
    if (posMs < startMs || posMs >= endMs) continue;
    final span = td.inMilliseconds;
    final t = span <= 0 ? 1.0 : ((posMs - startMs) / span).clamp(0.0, 1.0);
    return PreviewFadeWindow(
      afterIndex: i,
      t: t,
      outgoing: outgoing,
      incoming: incoming,
      td: td,
    );
  }
  return null;
}

/// True when [outgoing] into [next] should soft-cut in preview (dual layer).
bool previewUsesFade(ClipSegment outgoing, ClipSegment next) {
  final plan = TransitionEngine.instance.plan(outgoing.transition);
  if (plan.previewKind != TransitionPreviewKind.dualLayer) return false;
  return clampedTransitionDuration(outgoing, next: next) > Duration.zero;
}

/// Packed-timeline time of the cut **after** [afterIndex] (0..n-2).
///
/// Duration-preserving: cut sits at the hard-cut offset (sum of prior durations).
Duration cutExportTimeAfter(List<ClipSegment> segments, int afterIndex) {
  var offset = Duration.zero;
  for (var i = 0; i <= afterIndex && i < segments.length; i++) {
    offset += segments[i].duration;
  }
  return offset;
}

/// Packed-timeline span of a cut transition, centered on the cut:
/// `[C − ⌊td/2⌋, C + ⌈td/2⌉)`.
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
  final half = transitionHalfMs(td);
  var startMs = cut.inMilliseconds - half.before;
  var endMs = cut.inMilliseconds + half.after;
  final totalMs = exportTimelineDuration(segments).inMilliseconds;
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
  if (segments.isEmpty) return sourceTime;
  var offset = Duration.zero;
  for (var i = 0; i < segments.length; i++) {
    final segment = segments[i];
    if (sourceTime >= segment.start && sourceTime < segment.end) {
      return offset + (sourceTime - segment.start);
    }
    if (sourceTime == segment.end) {
      return offset + segment.duration;
    }
    offset += segment.duration;
    // Duration-preserving: flag kept for API compat (does not shorten).
    if (applyTransitions) {}
  }
  // Past every kept source frame: continue linearly after packed video.
  var maxEnd = Duration.zero;
  for (final segment in segments) {
    if (segment.end > maxEnd) maxEnd = segment.end;
  }
  if (sourceTime > maxEnd) {
    return totalKeptDuration(segments) + (sourceTime - maxEnd);
  }
  return null;
}

/// Maps edited timeline position back to source time.
Duration exportTimeToSourceTime(
  List<ClipSegment> segments,
  Duration exportTime, {
  bool applyTransitions = false,
}) {
  if (segments.isEmpty) return exportTime < Duration.zero ? Duration.zero : exportTime;
  if (exportTime <= Duration.zero) return segments.first.start;

  var offset = Duration.zero;
  for (var i = 0; i < segments.length; i++) {
    final segment = segments[i];
    final nextOffset = offset + segment.duration;
    if (exportTime < nextOffset) {
      return segment.start + (exportTime - offset);
    }
    offset = nextOffset;
    if (applyTransitions) {}
  }
  // Past packed video: keep advancing source time so layers can live after EOF.
  return segments.last.end + (exportTime - offset);
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
  // Multi-source: overlay times live on the packed sequence clock.
  if (segments.any((s) => s.mediaId != null)) {
    if (overlay.end <= overlay.start) return null;
    return (start: overlay.start, end: overlay.end);
  }
  // Direct mapping first so text can live (and move) past the video end.
  final directStart = sourceTimeToExportTime(segments, overlay.start);
  final directEnd = sourceTimeToExportTime(segments, overlay.end) ??
      overlayExportTimeForEnd(segments, overlay.end);
  if (directStart != null && directEnd != null && directEnd > directStart) {
    return (start: directStart, end: directEnd);
  }

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
  if (segments.isEmpty) return true;
  if (isInKeptRegion(segments, position)) return true;
  // The player often parks on the closed end of the last frame (`t == end`),
  // and music/text may continue past video EOF. Still show overlays timed there.
  return position >= segments.last.end;
}

/// Export-time windows where playback would show [overlay].
///
/// Touching clips stay one window, matching the timeline. A deleted gap stays
/// two windows. [sourceStartMs] is the source time at [start], so motion can
/// keep counting from the overlay's own start across a gap.
List<({double start, double end, int sourceStartMs})> overlayExportSpans(
  TextOverlay overlay,
  List<ClipSegment> segments,
) {
  final exportDurationSec =
      exportTimelineDuration(segments).inMilliseconds / 1000.0;
  final spans = <({double start, double end, int sourceStartMs})>[];

  for (final range in overlayTimelineRanges(overlay, segments)) {
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
    spans.add((
      start: clampedStart,
      end: clampedEnd,
      sourceStartMs: range.start.inMilliseconds,
    ));
  }

  return spans;
}
