/// A browsable royalty-free track from an external catalog.
class RoyaltyFreeTrack {
  const RoyaltyFreeTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.duration,
    required this.previewUrl,
    required this.downloadAllowed,
    this.licenseUrl,
  });

  final String id;
  final String title;
  final String artist;
  final Duration duration;
  final String previewUrl;
  final bool downloadAllowed;
  final String? licenseUrl;
}
