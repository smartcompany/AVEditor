/// Maps visibility between YouTube Shorts and TikTok Direct Post.
abstract final class CrossPostPrivacy {
  /// YouTube `privacyStatus` → best matching TikTok `privacy_level`.
  static String? youtubeToTikTok(
    String youtubePrivacy,
    List<String> tikTokOptions,
  ) {
    final preferred = switch (youtubePrivacy) {
      'public' => const [
        'PUBLIC_TO_EVERYONE',
        'FOLLOWER_OF_CREATOR',
        'MUTUAL_FOLLOW_FRIENDS',
        'SELF_ONLY',
      ],
      'unlisted' => const [
        'FOLLOWER_OF_CREATOR',
        'MUTUAL_FOLLOW_FRIENDS',
        'SELF_ONLY',
        'PUBLIC_TO_EVERYONE',
      ],
      _ => const [
        'SELF_ONLY',
        'MUTUAL_FOLLOW_FRIENDS',
        'FOLLOWER_OF_CREATOR',
        'PUBLIC_TO_EVERYONE',
      ],
    };
    for (final id in preferred) {
      if (tikTokOptions.contains(id)) return id;
    }
    return tikTokOptions.isEmpty ? null : tikTokOptions.first;
  }

  /// TikTok `privacy_level` → YouTube `privacyStatus`.
  static String tikTokToYouTube(String tikTokPrivacy) {
    return switch (tikTokPrivacy) {
      'PUBLIC_TO_EVERYONE' => 'public',
      'MUTUAL_FOLLOW_FRIENDS' || 'FOLLOWER_OF_CREATOR' => 'unlisted',
      _ => 'private',
    };
  }
}
