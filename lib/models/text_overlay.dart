import 'package:aveditor/models/text_overlay_style.dart';
import 'package:aveditor/models/text_style_template.dart';
import 'package:aveditor/utils/timeline_math.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

/// Width of the coordinate space [TextOverlay] sizes are expressed in.
///
/// Sizes are stored in export-frame pixels rather than preview pixels so the
/// same project renders identically on any device and in the exported video.
const double kOverlayFrameWidth = 1080;
const double kOverlayFrameHeight = 1920;

const Object _unset = Object();

/// Time-bounded text overlay on the video preview.
///
/// [fontSize], [boxWidth] and [boxHeight] are measured in frame pixels — see
/// [kOverlayFrameWidth]. The box and the font scale together, so the text keeps
/// filling the box as it is resized.
///
/// Look resolution order: [packItemId] → [templateId] → Shorts [style] cycle.
class TextOverlay {
  TextOverlay({
    String? id,
    required this.text,
    required this.start,
    required this.end,
    this.fontSize = 84,
    this.color = Colors.white,
    this.style = TextOverlayStyle.plain,
    this.templateId,
    this.packItemId,
    this.alignment = Alignment.center,
    this.offset = Offset.zero,
    this.boxWidth = 540,
    this.boxHeight = 264,
    this.rotation = 0,
    this.lane = 0,
  }) : id = id ?? const Uuid().v4();

  final String id;
  String text;
  Duration start;
  Duration end;
  double fontSize;
  Color color;
  TextOverlayStyle style;

  /// Built-in Word Art preset id, or null for the basic [style] cycle.
  String? templateId;

  /// Installed / bundled server-pack item id (Lottie + style).
  String? packItemId;
  Alignment alignment;

  /// Normalized offset from center. Values beyond ±1 place text past the frame edge.
  Offset offset;
  double boxWidth;
  double boxHeight;

  /// Clockwise rotation about the box centre, in radians.
  double rotation;

  /// Vertical text-lane index (0 = top). Overlapping clips go to new lanes.
  final int lane;

  TextStyleTemplate? get template => TextStyleTemplateCatalog.byId(templateId);

  TextOverlay copyWith({
    String? text,
    Duration? start,
    Duration? end,
    double? fontSize,
    Color? color,
    TextOverlayStyle? style,
    Object? templateId = _unset,
    Object? packItemId = _unset,
    Alignment? alignment,
    Offset? offset,
    double? boxWidth,
    double? boxHeight,
    double? rotation,
    int? lane,
  }) {
    return TextOverlay(
      id: id,
      text: text ?? this.text,
      start: start ?? this.start,
      end: end ?? this.end,
      fontSize: fontSize ?? this.fontSize,
      color: color ?? this.color,
      style: style ?? this.style,
      templateId: identical(templateId, _unset)
          ? this.templateId
          : templateId as String?,
      packItemId: identical(packItemId, _unset)
          ? this.packItemId
          : packItemId as String?,
      alignment: alignment ?? this.alignment,
      offset: offset ?? this.offset,
      boxWidth: boxWidth ?? this.boxWidth,
      boxHeight: boxHeight ?? this.boxHeight,
      rotation: rotation ?? this.rotation,
      lane: lane ?? this.lane,
    );
  }

  /// An independent copy — same look and timing, new identity.
  TextOverlay duplicate({Offset? offset}) {
    return TextOverlay(
      text: text,
      start: start,
      end: end,
      fontSize: fontSize,
      color: color,
      style: style,
      templateId: templateId,
      packItemId: packItemId,
      alignment: alignment,
      offset: offset ?? this.offset,
      boxWidth: boxWidth,
      boxHeight: boxHeight,
      rotation: rotation,
      lane: lane,
    );
  }

  bool isVisibleAt(Duration position) {
    return position >= start && position < end;
  }

  Duration get span => end - start;

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'startMs': start.inMilliseconds,
    'endMs': end.inMilliseconds,
    'fontSize': fontSize,
    'color': color.toARGB32(),
    'style': style.name,
    if (templateId != null) 'templateId': templateId,
    if (packItemId != null) 'packItemId': packItemId,
    'alignmentX': alignment.x,
    'alignmentY': alignment.y,
    'offsetDx': offset.dx,
    'offsetDy': offset.dy,
    'boxWidth': boxWidth,
    'boxHeight': boxHeight,
    'rotation': rotation,
    'lane': lane,
  };

  factory TextOverlay.fromJson(Map<String, dynamic> json) {
    return TextOverlay(
      id: json['id'] as String,
      text: json['text'] as String,
      start: Duration(milliseconds: json['startMs'] as int),
      end: Duration(milliseconds: json['endMs'] as int),
      fontSize: (json['fontSize'] as num).toDouble(),
      color: Color(json['color'] as int),
      style: TextOverlayStyle.fromJson(json['style'] as String?),
      templateId: json['templateId'] as String?,
      packItemId: json['packItemId'] as String?,
      alignment: Alignment(
        (json['alignmentX'] as num?)?.toDouble() ?? 0,
        (json['alignmentY'] as num?)?.toDouble() ?? 0,
      ),
      offset: Offset(
        (json['offsetDx'] as num).toDouble(),
        (json['offsetDy'] as num).toDouble(),
      ),
      boxWidth: (json['boxWidth'] as num).toDouble(),
      boxHeight: (json['boxHeight'] as num).toDouble(),
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
      lane: json['lane'] as int? ?? 0,
    );
  }
}

/// Split [overlay] at [at] (source timeline). Returns null if too close to edges.
(TextOverlay left, TextOverlay right)? splitTextOverlay(
  TextOverlay overlay,
  Duration at,
) {
  if (at <= overlay.start + minOverlayDuration) return null;
  if (at >= overlay.end - minOverlayDuration) return null;

  final left = overlay.copyWith(end: at);
  final right = overlay.duplicate().copyWith(
    start: at,
    end: overlay.end,
  );
  return (left, right);
}

bool overlayRangesOverlap(TextOverlay a, TextOverlay b) {
  return a.start < b.end && b.start < a.end;
}

/// Assigns a lane for [clip].
///
/// When [preferLowestLane] is true (default — CapCut-style), fills the oldest
/// free lane that has room for [clip]'s time range, so a clip dragged clear of
/// an upper neighbor can move back up. Only then opens a new lane.
///
/// When false, keeps [clip.lane] when free; on conflict prefers a lane below,
/// then above.
TextOverlay assignOverlayLane(
  List<TextOverlay> overlays,
  TextOverlay clip, {
  bool preferLowestLane = true,
}) {
  final others = overlays.where((o) => o.id != clip.id);
  bool fits(int lane) {
    for (final other in others) {
      if (other.lane != lane) continue;
      if (overlayRangesOverlap(other, clip)) return false;
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
List<TextOverlay> compactOverlayLanes(List<TextOverlay> overlays) {
  if (overlays.isEmpty) return overlays;
  final used = overlays.map((o) => o.lane).toSet().toList()..sort();
  final remap = <int, int>{
    for (var i = 0; i < used.length; i++) used[i]: i,
  };
  return [
    for (final overlay in overlays)
      remap[overlay.lane] == overlay.lane
          ? overlay
          : overlay.copyWith(lane: remap[overlay.lane]!),
  ];
}

int overlayLaneCount(List<TextOverlay> overlays) {
  if (overlays.isEmpty) return 0;
  var maxLane = 0;
  for (final overlay in overlays) {
    if (overlay.lane > maxLane) maxLane = overlay.lane;
  }
  return maxLane + 1;
}

/// Packs overlays onto the lowest free lanes from list order (load / migrate).
List<TextOverlay> resolveOverlayLanes(List<TextOverlay> overlays) {
  final placed = <TextOverlay>[];
  for (final overlay in overlays) {
    placed.add(assignOverlayLane(placed, overlay));
  }
  return compactOverlayLanes(placed);
}
