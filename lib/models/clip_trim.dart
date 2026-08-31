/// Trim range applied to the source clip.
class ClipTrim {
  const ClipTrim({
    required this.start,
    required this.end,
  });

  final Duration start;
  final Duration end;

  Duration get duration => end - start;

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
