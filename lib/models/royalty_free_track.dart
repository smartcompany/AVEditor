import 'package:aveditor/models/project_music.dart';

/// A browsable royalty-free track from an external catalog.
class RoyaltyFreeTrack {
  const RoyaltyFreeTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.duration,
    required this.previewUrl,
    required this.downloadAllowed,
    this.imageUrl = '',
    this.licenseUrl,
    this.downloadUrl,
    this.source = MusicSource.pixabay,
  });

  final String id;
  final String title;
  final String artist;
  final Duration duration;
  final String previewUrl;
  final String imageUrl;
  final bool downloadAllowed;
  final String? licenseUrl;

  /// Absolute URL to fetch the file (CDN or server proxy).
  final String? downloadUrl;
  final MusicSource source;

  factory RoyaltyFreeTrack.fromJson(Map<String, dynamic> json) {
    final durationSec = (json['durationSec'] as num?)?.toInt() ??
        (json['duration'] as num?)?.toInt() ??
        0;
    final id = '${json['id']}';
    return RoyaltyFreeTrack(
      id: id,
      title: json['title'] as String? ?? json['name'] as String? ?? 'Untitled',
      artist: json['artist'] as String? ??
          json['artist_name'] as String? ??
          'Unknown artist',
      duration: Duration(seconds: durationSec),
      previewUrl: json['previewUrl'] as String? ?? json['audio'] as String? ?? '',
      imageUrl: json['imageUrl'] as String? ?? json['image'] as String? ?? '',
      downloadAllowed: json['downloadAllowed'] as bool? ??
          json['audiodownload_allowed'] as bool? ??
          true,
      licenseUrl: json['licenseUrl'] as String? ?? json['license_ccurl'] as String?,
      downloadUrl: json['downloadUrl'] as String?,
      source: catalogSourceFrom(json['provider'] as String?, id),
    );
  }
}

MusicSource catalogSourceFrom(String? provider, String id) {
  switch (provider) {
    case 'mixkit':
      return MusicSource.mixkit;
    case 'pixabay':
      return MusicSource.pixabay;
    case 'jamendo':
      return MusicSource.jamendo;
  }
  if (id.startsWith('mixkit-')) return MusicSource.mixkit;
  if (id.startsWith('pixabay-')) return MusicSource.pixabay;
  return MusicSource.pixabay;
}
