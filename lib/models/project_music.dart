import 'package:uuid/uuid.dart';

/// Background music attached to a project.
class ProjectMusic {
  ProjectMusic({
    String? id,
    required this.title,
    this.artist,
    required this.fileName,
    this.timelineStart = Duration.zero,
    this.sourceOffset = Duration.zero,
    this.volume = 0.85,
    this.licenseUrl,
    this.source = MusicSource.local,
    this.externalId,
  }) : id = id ?? const Uuid().v4();

  final String id;
  final String title;
  final String? artist;

  /// Basename of the audio file inside the project folder.
  final String fileName;
  final Duration timelineStart;
  final Duration sourceOffset;
  final double volume;
  final String? licenseUrl;
  final MusicSource source;
  final String? externalId;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    if (artist != null) 'artist': artist,
    'fileName': fileName,
    'timelineStartMs': timelineStart.inMilliseconds,
    'sourceOffsetMs': sourceOffset.inMilliseconds,
    'volume': volume,
    if (licenseUrl != null) 'licenseUrl': licenseUrl,
    'source': source.name,
    if (externalId != null) 'externalId': externalId,
  };

  factory ProjectMusic.fromJson(Map<String, dynamic> json) {
    return ProjectMusic(
      id: json['id'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String?,
      fileName: json['fileName'] as String,
      timelineStart: Duration(milliseconds: json['timelineStartMs'] as int? ?? 0),
      sourceOffset: Duration(milliseconds: json['sourceOffsetMs'] as int? ?? 0),
      volume: (json['volume'] as num?)?.toDouble() ?? 0.85,
      licenseUrl: json['licenseUrl'] as String?,
      source: MusicSource.values.byName(json['source'] as String? ?? 'local'),
      externalId: json['externalId'] as String?,
    );
  }

  ProjectMusic copyWith({
    String? title,
    String? artist,
    String? fileName,
    Duration? timelineStart,
    Duration? sourceOffset,
    double? volume,
    String? licenseUrl,
    MusicSource? source,
    String? externalId,
  }) {
    return ProjectMusic(
      id: id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      fileName: fileName ?? this.fileName,
      timelineStart: timelineStart ?? this.timelineStart,
      sourceOffset: sourceOffset ?? this.sourceOffset,
      volume: volume ?? this.volume,
      licenseUrl: licenseUrl ?? this.licenseUrl,
      source: source ?? this.source,
      externalId: externalId ?? this.externalId,
    );
  }
}

enum MusicSource { local, jamendo }
