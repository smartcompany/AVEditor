/// Trim range applied to the source clip.
class ClipTrim {
  const ClipTrim({
    required this.start,
    required this.end,
  });

  final Duration start;
  final Duration end;

  Duration get duration => end - start;

  Map<String, dynamic> toJson() => {
    'startMs': start.inMilliseconds,
    'endMs': end.inMilliseconds,
  };

  factory ClipTrim.fromJson(Map<String, dynamic> json) {
    return ClipTrim(
      start: Duration(milliseconds: json['startMs'] as int),
      end: Duration(milliseconds: json['endMs'] as int),
    );
  }

  ClipTrim copyWith({
    Duration? start,
    Duration? end,
  }) {
    return ClipTrim(
      start: start ?? this.start,
      end: end ?? this.end,
    );
  }
}
