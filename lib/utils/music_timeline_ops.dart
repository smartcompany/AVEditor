import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/project_music.dart';
import 'package:aveditor/utils/clip_segment_ops.dart';

/// Maps a music clip's source range onto the packed sequence timeline.
({Duration start, Duration end})? musicSequenceSpan(
  ProjectMusic music,
  List<ClipSegment> segments,
) {
  if (segments.isEmpty) {
    return (start: music.timelineStart, end: music.timelineEnd);
  }

  var exportStart = sourceTimeToExportTime(segments, music.timelineStart);
  exportStart ??= sourceTimeToExportTime(segments, segments.first.start);
  if (exportStart == null) return null;

  var exportEnd = sourceTimeToExportTime(segments, music.timelineEnd);
  exportEnd ??= sourceTimeToExportTime(segments, segments.last.end);
  if (exportEnd == null) return null;
  if (exportEnd < exportStart) return null;
  if (exportEnd == exportStart) {
    exportEnd = exportStart + minMusicClipDuration;
  }
  return (start: exportStart, end: exportEnd);
}
