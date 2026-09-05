import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/project_music.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/video_project.dart';

/// Immutable editor state used for undo/redo.
class EditorSnapshot {
  const EditorSnapshot({
    required this.segments,
    required this.overlays,
    required this.rotation,
    required this.musicTracks,
    this.selectedSegmentId,
    this.selectedOverlayId,
    this.selectedMusicId,
  });

  final List<ClipSegment> segments;
  final List<TextOverlay> overlays;
  final double rotation;
  final List<ProjectMusic> musicTracks;
  final String? selectedSegmentId;
  final String? selectedOverlayId;
  final String? selectedMusicId;

  factory EditorSnapshot.fromProject(
    VideoProject project, {
    String? selectedSegmentId,
    String? selectedOverlayId,
    String? selectedMusicId,
  }) {
    return EditorSnapshot(
      segments: project.segments
          .map((segment) => segment.copyWith())
          .toList(growable: false),
      overlays: _cloneOverlays(project.overlays),
      rotation: project.rotation,
      musicTracks: project.musicTracks
          .map((m) => m.copyWith())
          .toList(growable: false),
      selectedSegmentId: selectedSegmentId,
      selectedOverlayId: selectedOverlayId,
      selectedMusicId: selectedMusicId,
    );
  }

  void applyTo(VideoProject project) {
    project.segments
      ..clear()
      ..addAll(segments.map((segment) => segment.copyWith()));
    project.overlays
      ..clear()
      ..addAll(_cloneOverlays(overlays));
    project.musicTracks
      ..clear()
      ..addAll(musicTracks.map((m) => m.copyWith()));
    project.rotation = rotation;
    project.touch();
  }

  static List<TextOverlay> _cloneOverlays(List<TextOverlay> overlays) {
    return overlays
        .map(
          (overlay) => overlay.copyWith(
            text: overlay.text,
            start: overlay.start,
            end: overlay.end,
            fontSize: overlay.fontSize,
            color: overlay.color,
            style: overlay.style,
            templateId: overlay.templateId,
            packItemId: overlay.packItemId,
            alignment: overlay.alignment,
            offset: overlay.offset,
            boxWidth: overlay.boxWidth,
            boxHeight: overlay.boxHeight,
            rotation: overlay.rotation,
            lane: overlay.lane,
          ),
        )
        .toList(growable: false);
  }
}

/// Stores undo/redo stacks for the editor.
class EditorHistory {
  static const _maxDepth = 50;

  final List<EditorSnapshot> _undo = [];
  final List<EditorSnapshot> _redo = [];

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void record(EditorSnapshot snapshot) {
    _undo.add(snapshot);
    if (_undo.length > _maxDepth) {
      _undo.removeAt(0);
    }
    _redo.clear();
  }

  EditorSnapshot? undo(EditorSnapshot current) {
    if (_undo.isEmpty) return null;
    _redo.add(current);
    return _undo.removeLast();
  }

  EditorSnapshot? redo(EditorSnapshot current) {
    if (_redo.isEmpty) return null;
    _undo.add(current);
    return _redo.removeLast();
  }

  void clear() {
    _undo.clear();
    _redo.clear();
  }
}
