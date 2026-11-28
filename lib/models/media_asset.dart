import 'package:uuid/uuid.dart';

/// Soft ceiling when dragging an image clip's right edge (hold length).
const Duration kMaxImageHoldDuration = Duration(minutes: 5);

/// Default on-timeline length for a newly imported still.
const Duration kDefaultImageHoldDuration = Duration(seconds: 3);

/// Default hold for server-driven background templates (prologue / epilogue).
const Duration kDefaultBackgroundHoldDuration = Duration(seconds: 5);

enum MediaAssetKind { video, image }

/// One imported video or photo file inside a project folder.
class MediaAsset {
  MediaAsset({
    String? id,
    required this.fileName,
    required this.kind,
    this.duration = Duration.zero,
    this.libraryAssetId,
  }) : id = id ?? const Uuid().v4();

  final String id;

  /// Path relative to the project directory (e.g. `media/<id>.mp4`), or an
  /// absolute session path when this asset is a gallery library reference.
  final String fileName;

  final MediaAssetKind kind;

  /// Natural length of a video file. Zero for images.
  final Duration duration;

  /// Durable Photos / MediaStore id (`photo_manager` [AssetEntity.id]).
  ///
  /// When set, the project can reopen without a Documents copy by resolving
  /// a fresh playable path from the system library.
  final String? libraryAssetId;

  bool get isImage => kind == MediaAssetKind.image;
  bool get isVideo => kind == MediaAssetKind.video;

  /// True when this asset is opened by library reference (no project copy).
  bool get isLibraryReference =>
      libraryAssetId != null && libraryAssetId!.trim().isNotEmpty;

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
        if (libraryAssetId != null && libraryAssetId!.trim().isNotEmpty)
          'libraryAssetId': libraryAssetId,
      };

  factory MediaAsset.fromJson(Map<String, dynamic> json) {
    final kindName = json['kind'] as String? ?? 'video';
    final kind = MediaAssetKind.values.firstWhere(
      (k) => k.name == kindName,
      orElse: () => MediaAssetKind.video,
    );
    final libraryId = json['libraryAssetId'] as String?;
    return MediaAsset(
      id: json['id'] as String,
      fileName: json['fileName'] as String,
      kind: kind,
      duration: Duration(milliseconds: (json['durationMs'] as num?)?.toInt() ?? 0),
      libraryAssetId: libraryId != null && libraryId.trim().isEmpty
          ? null
          : libraryId,
    );
  }

  MediaAsset copyWith({
    String? id,
    String? fileName,
    MediaAssetKind? kind,
    Duration? duration,
    String? libraryAssetId,
    bool clearLibraryAssetId = false,
  }) {
    return MediaAsset(
      id: id ?? this.id,
      fileName: fileName ?? this.fileName,
      kind: kind ?? this.kind,
      duration: duration ?? this.duration,
      libraryAssetId: clearLibraryAssetId
          ? null
          : (libraryAssetId ?? this.libraryAssetId),
    );
  }
}
