import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

/// Time-bounded text overlay on the video preview.
class TextOverlay {
  TextOverlay({
    String? id,
    required this.text,
    required this.start,
    required this.end,
    this.fontSize = 28,
    this.color = Colors.white,
    this.alignment = Alignment.center,
    this.offset = Offset.zero,
    this.boxWidth = 180,
    this.boxHeight = 88,
  }) : id = id ?? const Uuid().v4();

  final String id;
  String text;
  Duration start;
  Duration end;
  double fontSize;
  Color color;
  Alignment alignment;
  /// Normalized offset from center. Values beyond ±1 place text past the frame edge.
  Offset offset;
  /// Preview box width/height in logical pixels (independent resize).
  double boxWidth;
  double boxHeight;

  TextOverlay copyWith({
    String? text,
    Duration? start,
    Duration? end,
    double? fontSize,
    Color? color,
    Alignment? alignment,
    Offset? offset,
    double? boxWidth,
    double? boxHeight,
  }) {
    return TextOverlay(
      id: id,
      text: text ?? this.text,
      start: start ?? this.start,
      end: end ?? this.end,
      fontSize: fontSize ?? this.fontSize,
      color: color ?? this.color,
      alignment: alignment ?? this.alignment,
      offset: offset ?? this.offset,
      boxWidth: boxWidth ?? this.boxWidth,
      boxHeight: boxHeight ?? this.boxHeight,
    );
  }

  bool isVisibleAt(Duration position) {
    return position >= start && position < end;
  }

  Duration get span => end - start;
}
