import 'package:aveditor/models/text_overlay_style.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

/// Width of the coordinate space [TextOverlay] sizes are expressed in.
///
/// Sizes are stored in export-frame pixels rather than preview pixels so the
/// same project renders identically on any device and in the exported video.
const double kOverlayFrameWidth = 1080;
const double kOverlayFrameHeight = 1920;

/// Time-bounded text overlay on the video preview.
///
/// [fontSize], [boxWidth] and [boxHeight] are measured in frame pixels — see
/// [kOverlayFrameWidth]. The box and the font scale together, so the text keeps
/// filling the box as it is resized.
class TextOverlay {
  TextOverlay({
    String? id,
    required this.text,
    required this.start,
    required this.end,
    this.fontSize = 84,
    this.color = Colors.white,
    this.style = TextOverlayStyle.plain,
    this.alignment = Alignment.center,
    this.offset = Offset.zero,
    this.boxWidth = 540,
    this.boxHeight = 264,
    this.rotation = 0,
  }) : id = id ?? const Uuid().v4();

  final String id;
  String text;
  Duration start;
  Duration end;
  double fontSize;
  Color color;
  TextOverlayStyle style;
  Alignment alignment;
  /// Normalized offset from center. Values beyond ±1 place text past the frame edge.
  Offset offset;
  double boxWidth;
  double boxHeight;

  /// Clockwise rotation about the box centre, in radians.
  double rotation;

  TextOverlay copyWith({
    String? text,
    Duration? start,
    Duration? end,
    double? fontSize,
    Color? color,
    TextOverlayStyle? style,
    Alignment? alignment,
    Offset? offset,
    double? boxWidth,
    double? boxHeight,
    double? rotation,
  }) {
    return TextOverlay(
      id: id,
      text: text ?? this.text,
      start: start ?? this.start,
      end: end ?? this.end,
      fontSize: fontSize ?? this.fontSize,
      color: color ?? this.color,
      style: style ?? this.style,
      alignment: alignment ?? this.alignment,
      offset: offset ?? this.offset,
      boxWidth: boxWidth ?? this.boxWidth,
      boxHeight: boxHeight ?? this.boxHeight,
      rotation: rotation ?? this.rotation,
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
      alignment: alignment,
      offset: offset ?? this.offset,
      boxWidth: boxWidth,
      boxHeight: boxHeight,
      rotation: rotation,
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
    'alignmentX': alignment.x,
    'alignmentY': alignment.y,
    'offsetDx': offset.dx,
    'offsetDy': offset.dy,
    'boxWidth': boxWidth,
    'boxHeight': boxHeight,
    'rotation': rotation,
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
    );
  }
}
