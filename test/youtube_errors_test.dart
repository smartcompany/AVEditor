import 'dart:io';

import 'package:aveditor/services/youtube_errors.dart';
import 'package:flutter_test/flutter_test.dart';

YouTubeApiException _api(int status, String reason, [String message = '']) {
  return YouTubeApiException.fromResponse(
    step: 'upload',
    statusCode: status,
    body:
        '{"error":{"code":$status,"message":"$message",'
        '"errors":[{"message":"$message","domain":"youtube","reason":"$reason"}]}}',
  );
}

void main() {
  test('parses the Google error envelope instead of keeping raw JSON', () {
    final error = _api(
      403,
      'forbidden',
      'The YouTube account of the authenticated user is suspended.',
    );
    expect(error.statusCode, 403);
    expect(error.reason, 'forbidden');
    expect(error.code, '403 forbidden');
    expect(error.toString(), isNot(contains('{')));
  });

  test('non-JSON bodies fall back to the status code', () {
    final error = YouTubeApiException.fromResponse(
      step: 'thumbnail',
      statusCode: 502,
      body: '<html>Bad Gateway</html>',
    );
    expect(error.code, '502');
    expect(classifyYouTubeError(error), YouTubeErrorKind.unknown);
  });

  test('suspended channel suggests switching account', () {
    final kind = classifyYouTubeError(
      _api(
        403,
        'forbidden',
        'The YouTube account of the authenticated user is suspended.',
      ),
    );
    expect(kind, YouTubeErrorKind.accountSuspended);
    expect(kind.suggestsSwitchAccount, isTrue);
  });

  test('classifies common YouTube reasons', () {
    expect(
      classifyYouTubeError(_api(401, 'youtubeSignupRequired')),
      YouTubeErrorKind.noChannel,
    );
    expect(
      classifyYouTubeError(_api(400, 'uploadLimitExceeded')),
      YouTubeErrorKind.uploadLimit,
    );
    expect(
      classifyYouTubeError(_api(403, 'quotaExceeded')),
      YouTubeErrorKind.quota,
    );
    expect(
      classifyYouTubeError(_api(401, 'authError')),
      YouTubeErrorKind.authExpired,
    );
    expect(
      classifyYouTubeError(_api(403, 'insufficientPermissions')),
      YouTubeErrorKind.permissionDenied,
    );
    expect(YouTubeErrorKind.quota.suggestsSwitchAccount, isFalse);
  });

  test('classifies sign-in and network failures', () {
    expect(
      classifyYouTubeError(const YouTubeSignInCancelled()),
      YouTubeErrorKind.cancelled,
    );
    expect(
      classifyYouTubeError(const YouTubePermissionDenied('upload')),
      YouTubeErrorKind.permissionDenied,
    );
    expect(
      classifyYouTubeError(const SocketException('Failed host lookup')),
      YouTubeErrorKind.network,
    );
  });
}
