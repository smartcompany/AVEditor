import 'package:uuid/uuid.dart';

/// Soft ceiling when dragging an image clip's right edge (hold length).
const Duration kMaxImageHoldDuration = Duration(minutes: 5);

/// Default on-timeline length for a newly imported still.
const Duration kDefaultImageHoldDuration = Duration(seconds: 3);

enum MediaAssetKind { video, image }

/// One imported video or photo file inside a project folder.
class MediaAsset {
  MediaAsset({
    String? id,
    required this.fileName,
    required this.kind,
    this.duration = Duration.zero,
  }) : id = id ?? const Uuid().v4();

  final String id;

  /// Path relative to the project directory (e.g. `media/<id>.mp4`).
  final String fileName;

  final MediaAssetKind kind;

  /// Natural length of a video file. Zero for images.
  final Duration duration;

  bool get isImage => kind == MediaAssetKind.image;
  bool get isVideo => kind == MediaAssetKind.video;

  /// Max in-point / out-point for trims on this asset.
  Duration get maxClipEnd =>
      isImage ? kMaxImageHoldDuration : (duration <= Duration.zero
          ? const Duration(hours: 12)
          : duration);

  Map<String, dynamic> toJson() => {
        'id': id,
        'fileName': fileName,
        'kind': kind.name,
        'durationMs': duration.inMilliseconds,
      };

  factory MediaAsset.fromJson(Map<String, dynamic> json) {
    final kindName = json['kind'] as String? ?? 'video';
    final kind = MediaAssetKind.values.firstWhere(
      (k) => k.name == kindName,
      orElse: () => MediaAssetKind.video,
    );
    return MediaAsset(
      id: json['id'] as String,
      fileName: json['fileName'] as String,
      kind: kind,
      duration: Duration(milliseconds: (json['durationMs'] as num?)?.toInt() ?? 0),
    );
  }

  MediaAsset copyWith({
    String? id,
    String? fileName,
    MediaAssetKind? kind,
    Duration? duration,
  }) {
    return MediaAsset(
      id: id ?? this.id,
      fileName: fileName ?? this.fileName,
      kind: kind ?? this.kind,
      duration: duration ?? this.duration,
    );
  }
}
