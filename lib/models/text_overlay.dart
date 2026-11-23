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

/// Default sticker box in frame pixels (~square CapCut-style stamp).
const double kDefaultStickerBox = 320;

const Object _unset = Object();

enum OverlayKind { text, sticker }

/// Time-bounded text or sticker overlay on the video preview.
///
/// [fontSize], [boxWidth] and [boxHeight] are measured in frame pixels — see
/// [kOverlayFrameWidth]. The box and the font scale together, so the text keeps
/// filling the box as it is resized.
///
/// Look resolution order (text): [packItemId] → [templateId] → Shorts [style].
class TextOverlay {
  TextOverlay({
    String? id,
    required this.text,
    required this.start,
    required this.end,
    this.kind = OverlayKind.text,
    this.fontSize = 120,
    this.color = Colors.white,
    this.style = TextOverlayStyle.plain,
    this.templateId,
    this.packItemId,
    this.fontFamily,
    this.textAlign = TextAlign.center,
    this.alignment = Alignment.center,
    this.offset = Offset.zero,
    this.boxWidth = 200,
    this.boxHeight = 100,
    this.rotation = 0,
    this.lane = 0,
    this.animationId,
    this.animationDurationMs,
    this.stickerLocalPath,
    this.stickerGiphyId,
    this.stickerPreviewUrl,
  }) : id = id ?? const Uuid().v4();

  final String id;
  String text;
  Duration start;
  Duration end;

  /// `text` (default) or Giphy/image `sticker`.
  final OverlayKind kind;

  double fontSize;
  Color color;
  TextOverlayStyle style;

  /// Built-in Word Art preset id, or null for the basic [style] cycle.
  String? templateId;

  /// Installed / bundled server-pack item id (Lottie + style).
  String? packItemId;

  /// Font id from [OverlayFonts] (`null` / `overlay` = bundled default).
  String? fontFamily;

  /// Horizontal alignment inside the text box (Shorts-style left/center/right).
  TextAlign textAlign;

  Alignment alignment;

  /// Normalized offset from center. Values beyond ±1 place text past the frame edge.
  Offset offset;
  double boxWidth;
  double boxHeight;

  /// Clockwise rotation about the box centre, in radians.
  double rotation;

  /// Vertical text-lane index (0 = top). Overlapping clips go to new lanes.
  final int lane;

  /// Entrance animation override. `null` = use pack default; `''` = force none.
  String? animationId;

  /// Optional override for entrance duration (ms).
  int? animationDurationMs;

  /// Project-relative GIF path (e.g. `media/stickers/<id>.gif`).
  String? stickerLocalPath;

  String? stickerGiphyId;
  String? stickerPreviewUrl;

  bool get isSticker => kind == OverlayKind.sticker;

  TextStyleTemplate? get template => TextStyleTemplateCatalog.byId(templateId);

  TextOverlay copyWith({
    String? text,
    Duration? start,
    Duration? end,
    OverlayKind? kind,
    double? fontSize,
    Color? color,
    TextOverlayStyle? style,
    Object? templateId = _unset,
    Object? packItemId = _unset,
    Object? fontFamily = _unset,
    TextAlign? textAlign,
    Alignment? alignment,
    Offset? offset,
    double? boxWidth,
    double? boxHeight,
    double? rotation,
    int? lane,
    Object? animationId = _unset,
    Object? animationDurationMs = _unset,
    Object? stickerLocalPath = _unset,
    Object? stickerGiphyId = _unset,
    Object? stickerPreviewUrl = _unset,
  }) {
    return TextOverlay(
      id: id,
      text: text ?? this.text,
      start: start ?? this.start,
      end: end ?? this.end,
      kind: kind ?? this.kind,
      fontSize: fontSize ?? this.fontSize,
      color: color ?? this.color,
      style: style ?? this.style,
      templateId: identical(templateId, _unset)
          ? this.templateId
          : templateId as String?,
      packItemId: identical(packItemId, _unset)
          ? this.packItemId
          : packItemId as String?,
      fontFamily: identical(fontFamily, _unset)
          ? this.fontFamily
          : fontFamily as String?,
      textAlign: textAlign ?? this.textAlign,
      alignment: alignment ?? this.alignment,
      offset: offset ?? this.offset,
      boxWidth: boxWidth ?? this.boxWidth,
      boxHeight: boxHeight ?? this.boxHeight,
      rotation: rotation ?? this.rotation,
      lane: lane ?? this.lane,
      animationId: identical(animationId, _unset)
          ? this.animationId
          : animationId as String?,
      animationDurationMs: identical(animationDurationMs, _unset)
          ? this.animationDurationMs
          : animationDurationMs as int?,
      stickerLocalPath: identical(stickerLocalPath, _unset)
          ? this.stickerLocalPath
          : stickerLocalPath as String?,
      stickerGiphyId: identical(stickerGiphyId, _unset)
          ? this.stickerGiphyId
          : stickerGiphyId as String?,
      stickerPreviewUrl: identical(stickerPreviewUrl, _unset)
          ? this.stickerPreviewUrl
          : stickerPreviewUrl as String?,
    );
  }

  /// An independent copy — same look and timing, new identity.
  TextOverlay duplicate({Offset? offset}) {
    return TextOverlay(
      text: text,
      start: start,
      end: end,
      kind: kind,
      fontSize: fontSize,
      color: color,
      style: style,
      templateId: templateId,
      packItemId: packItemId,
      fontFamily: fontFamily,
      textAlign: textAlign,
      alignment: alignment,
      offset: offset ?? this.offset,
      boxWidth: boxWidth,
      boxHeight: boxHeight,
      rotation: rotation,
      lane: lane,
      animationId: animationId,
      animationDurationMs: animationDurationMs,
      stickerLocalPath: stickerLocalPath,
      stickerGiphyId: stickerGiphyId,
      stickerPreviewUrl: stickerPreviewUrl,
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
    if (kind != OverlayKind.text) 'kind': kind.name,
    'fontSize': fontSize,
    'color': color.toARGB32(),
    'style': style.name,
    if (templateId != null) 'templateId': templateId,
    if (packItemId != null) 'packItemId': packItemId,
    if (fontFamily != null) 'fontFamily': fontFamily,
    if (animationId != null) 'animationId': animationId,
    if (animationDurationMs != null) 'animationDurationMs': animationDurationMs,
    if (stickerLocalPath != null) 'stickerLocalPath': stickerLocalPath,
    if (stickerGiphyId != null) 'stickerGiphyId': stickerGiphyId,
    if (stickerPreviewUrl != null) 'stickerPreviewUrl': stickerPreviewUrl,
    'textAlign': textAlign.name,
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
      text: json['text'] as String? ?? '',
      start: Duration(milliseconds: json['startMs'] as int),
      end: Duration(milliseconds: json['endMs'] as int),
      kind: _kindFromJson(json['kind'] as String?),
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 120,
      color: Color((json['color'] as int?) ?? Colors.white.toARGB32()),
      style: TextOverlayStyle.fromJson(json['style'] as String?),
      templateId: json['templateId'] as String?,
      packItemId: json['packItemId'] as String?,
      fontFamily: json['fontFamily'] as String?,
      animationId: json['animationId'] as String?,
      animationDurationMs: json['animationDurationMs'] as int?,
      stickerLocalPath: json['stickerLocalPath'] as String?,
      stickerGiphyId: json['stickerGiphyId'] as String?,
      stickerPreviewUrl: json['stickerPreviewUrl'] as String?,
      textAlign: _textAlignFromJson(json['textAlign'] as String?),
      alignment: Alignment(
        (json['alignmentX'] as num?)?.toDouble() ?? 0,
        (json['alignmentY'] as num?)?.toDouble() ?? 0,
      ),
      offset: Offset(
        (json['offsetDx'] as num?)?.toDouble() ?? 0,
        (json['offsetDy'] as num?)?.toDouble() ?? 0,
      ),
      boxWidth: (json['boxWidth'] as num?)?.toDouble() ?? 200,
      boxHeight: (json['boxHeight'] as num?)?.toDouble() ?? 100,
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
      lane: json['lane'] as int? ?? 0,
    );
  }
}

OverlayKind _kindFromJson(String? value) {
  if (value == 'sticker') return OverlayKind.sticker;
  return OverlayKind.text;
}

TextAlign _textAlignFromJson(String? value) {
  switch (value) {
    case 'left':
      return TextAlign.left;
    case 'right':
      return TextAlign.right;
    case 'justify':
      return TextAlign.justify;
    case 'start':
      return TextAlign.start;
    case 'end':
      return TextAlign.end;
    case 'center':
    default:
      return TextAlign.center;
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

/// Assigns a lane for [clip] among all overlays (text + stickers share lanes).
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
