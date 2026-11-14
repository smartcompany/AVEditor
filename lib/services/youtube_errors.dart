import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A non-success response from the YouTube Data API, kept structured so the
/// UI can explain it instead of printing the raw JSON body.
class YouTubeApiException implements Exception {
  YouTubeApiException({
    required this.step,
    required this.statusCode,
    this.reason = '',
    this.message = '',
  });

  /// Parses Google's error envelope: `{"error": {"code", "message",
  /// "errors": [{"reason", "message", "domain"}]}}`.
  factory YouTubeApiException.fromResponse({
    required String step,
    required int statusCode,
    required String body,
  }) {
    var reason = '';
    var message = '';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is Map) {
        final error = decoded['error'] as Map;
        message = '${error['message'] ?? ''}';
        final errors = error['errors'];
        if (errors is List && errors.isNotEmpty && errors.first is Map) {
          final first = errors.first as Map;
          reason = '${first['reason'] ?? ''}';
          if (message.isEmpty) message = '${first['message'] ?? ''}';
        }
      }
    } catch (_) {
      // Not JSON (HTML error page etc.): classify by status code only.
    }
    return YouTubeApiException(
      step: step,
      statusCode: statusCode,
      reason: reason,
      message: message,
    );
  }

  /// Which call failed: upload, thumbnail, playlist, ageRestriction, …
  final String step;
  final int statusCode;
  final String reason;
  final String message;

  /// Short code for the user / support (no JSON).
  String get code => reason.isEmpty ? '$statusCode' : '$statusCode $reason';

  @override
  String toString() => 'YouTubeApiException($step $code: $message)';
}

/// The user closed the Google account picker.
class YouTubeSignInCancelled implements Exception {
  const YouTubeSignInCancelled();
  @override
  String toString() => 'YouTube sign-in was cancelled';
}

/// The user declined the YouTube permission on the consent screen.
class YouTubePermissionDenied implements Exception {
  const YouTubePermissionDenied(this.scopeLabel);
  final String scopeLabel;
  @override
  String toString() => 'YouTube permission was not granted ($scopeLabel)';
}

enum YouTubeErrorKind {
  /// The signed-in account's YouTube channel is suspended.
  accountSuspended,

  /// The Google account has no YouTube channel yet.
  noChannel,

  /// The channel hit YouTube's daily upload limit.
  uploadLimit,

  /// The app's API quota or rate limit is used up.
  quota,

  /// Sign-in expired or the token was rejected.
  authExpired,

  /// The user declined the permission.
  permissionDenied,

  /// The user closed the account picker (not an error to show).
  cancelled,

  /// No connection / timed out.
  network,

  /// Anything else.
  unknown,
}

extension YouTubeErrorKindX on YouTubeErrorKind {
  /// Errors tied to the account itself, where signing in with a different
  /// Google account is the fix.
  bool get suggestsSwitchAccount =>
      this == YouTubeErrorKind.accountSuspended ||
      this == YouTubeErrorKind.noChannel ||
      this == YouTubeErrorKind.authExpired;
}

YouTubeErrorKind classifyYouTubeError(Object error) {
  if (error is YouTubeSignInCancelled) return YouTubeErrorKind.cancelled;
  if (error is YouTubePermissionDenied) return YouTubeErrorKind.permissionDenied;
  if (error is SocketException ||
      error is TimeoutException ||
      error is HttpException ||
      error is HandshakeException) {
    return YouTubeErrorKind.network;
  }
  if (error is! YouTubeApiException) {
    final text = '$error'.toLowerCase();
    if (text.contains('sign_in_canceled') || text.contains('cancelled')) {
      return YouTubeErrorKind.cancelled;
    }
    if (text.contains('network') || text.contains('socket')) {
      return YouTubeErrorKind.network;
    }
    return YouTubeErrorKind.unknown;
  }

  final reason = error.reason.toLowerCase();
  final message = error.message.toLowerCase();
  if (message.contains('suspended') || reason.contains('suspended')) {
    return YouTubeErrorKind.accountSuspended;
  }
  if (reason == 'youtubesignuprequired' ||
      reason == 'channelnotfound' ||
      message.contains('signup') ||
      message.contains('does not have a youtube channel')) {
    return YouTubeErrorKind.noChannel;
  }
  if (reason == 'uploadlimitexceeded') return YouTubeErrorKind.uploadLimit;
  if (reason == 'quotaexceeded' ||
      reason == 'dailylimitexceeded' ||
      reason == 'ratelimitexceeded' ||
      reason == 'userratelimitexceeded' ||
      error.statusCode == 429) {
    return YouTubeErrorKind.quota;
  }
  if (error.statusCode == 401 ||
      reason == 'autherror' ||
      reason == 'invalidcredentials') {
    return YouTubeErrorKind.authExpired;
  }
  if (reason == 'insufficientpermissions' ||
      message.contains('insufficient authentication scopes')) {
    return YouTubeErrorKind.permissionDenied;
  }
  return YouTubeErrorKind.unknown;
}
