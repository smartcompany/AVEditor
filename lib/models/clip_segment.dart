import 'package:uuid/uuid.dart';

/// A kept portion of the source clip, in source-timeline order.
class ClipSegment {
  ClipSegment({
    String? id,
    required this.start,
    required this.end,
  }) : id = id ?? const Uuid().v4();

  final String id;
  final Duration start;
  final Duration end;

  Duration get duration => end - start;

  Map<String, dynamic> toJson() => {
    'id': id,
    'startMs': start.inMilliseconds,
    'endMs': end.inMilliseconds,
  };

  factory ClipSegment.fromJson(Map<String, dynamic> json) {
    return ClipSegment(
      id: json['id'] as String,
      start: Duration(milliseconds: json['startMs'] as int),
      end: Duration(milliseconds: json['endMs'] as int),
    );
  }

  ClipSegment copyWith({
    String? id,
    Duration? start,
    Duration? end,
  }) {
    return ClipSegment(
      id: id ?? this.id,
      start: start ?? this.start,
      end: end ?? this.end,
    );
  }
}
