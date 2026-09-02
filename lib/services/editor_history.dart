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
    this.backgroundMusic,
    this.selectedSegmentId,
    this.selectedOverlayId,
  });

  final List<ClipSegment> segments;
  final List<TextOverlay> overlays;
  final double rotation;
  final ProjectMusic? backgroundMusic;
  final String? selectedSegmentId;
  final String? selectedOverlayId;

  factory EditorSnapshot.fromProject(
    VideoProject project, {
    String? selectedSegmentId,
    String? selectedOverlayId,
  }) {
    return EditorSnapshot(
      segments: project.segments
          .map((segment) => segment.copyWith())
          .toList(growable: false),
      overlays: _cloneOverlays(project.overlays),
      rotation: project.rotation,
      backgroundMusic: project.backgroundMusic?.copyWith(),
      selectedSegmentId: selectedSegmentId,
      selectedOverlayId: selectedOverlayId,
    );
  }

  void applyTo(VideoProject project) {
    project.segments
      ..clear()
      ..addAll(segments.map((segment) => segment.copyWith()));
    project.overlays
      ..clear()
      ..addAll(_cloneOverlays(overlays));
    project.rotation = rotation;
    project.backgroundMusic = backgroundMusic?.copyWith();
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
            alignment: overlay.alignment,
            offset: overlay.offset,
            boxWidth: overlay.boxWidth,
            boxHeight: overlay.boxHeight,
            rotation: overlay.rotation,
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
