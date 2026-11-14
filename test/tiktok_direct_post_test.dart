import 'dart:convert';
import 'dart:io';

import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/screens/tiktok_upload_screen.dart';
import 'package:aveditor/services/tiktok_auth_service.dart';
import 'package:aveditor/services/tiktok_post_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakeAuth extends TikTokAuthService {
  _FakeAuth(this.session);
  final TikTokSession? session;
  @override
  Future<TikTokSession?> currentSession() async => session;
}

class _FakePosts extends TikTokPostService {
  _FakePosts(this.info);
  final TikTokCreatorInfo info;
  @override
  Future<TikTokCreatorInfo> creatorInfo(String accessToken) async => info;
}

TikTokSession _session() => TikTokSession(
  accessToken: 'token',
  refreshToken: 'refresh',
  openId: 'open',
  expiresAt: DateTime.now().add(const Duration(hours: 1)),
  refreshExpiresAt: DateTime.now().add(const Duration(days: 30)),
  scope: 'user.info.basic,video.publish',
);

const _creator = TikTokCreatorInfo(
  nickname: 'Gunny',
  username: 'gunny',
  avatarUrl: '',
  privacyOptions: ['PUBLIC_TO_EVERYONE', 'SELF_ONLY'],
  commentDisabled: true,
  duetDisabled: false,
  stitchDisabled: false,
  maxDurationSeconds: 600,
);

/// The preview spinner never stops in tests, so pump a fixed time.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('chunk plan', () {
    test('small files go in one chunk', () {
      final plan = TikTokChunkPlan.forSize(3 * 1024 * 1024);
      expect(plan.chunkCount, 1);
      expect(plan.chunkSize, plan.videoSize);
      expect(plan.range(0), (0, plan.videoSize - 1));
    });

    test('large files fold the remainder into the last chunk', () {
      const mb = 1024 * 1024;
      final plan = TikTokChunkPlan.forSize(95 * mb + 123);
      expect(plan.chunkSize, 10 * mb);
      expect(plan.chunkCount, 9);
      expect(plan.range(0), (0, 10 * mb - 1));
      expect(plan.range(8), (80 * mb, 95 * mb + 122));
    });
  });

  test(
    'publish streams the file with Content-Range and reports progress',
    () async {
      final dir = await Directory.systemTemp.createTemp('tiktok_upload');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/v.mp4')
        ..writeAsBytesSync(List.filled(300000, 7));
      String? range;
      var uploaded = 0;
      final client = MockClient.streaming((request, body) async {
        if (request.url.path.endsWith('/video/init/')) {
          final payload = jsonEncode({
            'data': {'publish_id': 'p1', 'upload_url': 'https://upload.test/u'},
            'error': {'code': 'ok'},
          });
          return http.StreamedResponse(Stream.value(utf8.encode(payload)), 200);
        }
        range = request.headers['Content-Range'];
        await for (final chunk in body) {
          uploaded += chunk.length;
        }
        return http.StreamedResponse(const Stream.empty(), 201);
      });
      final progress = <double>[];
      final id = await TikTokPostService(client: client).publish(
        accessToken: 't',
        file: file,
        info: const TikTokPostInfo(
          title: '',
          privacyLevel: 'SELF_ONLY',
          allowComment: false,
          allowDuet: false,
          allowStitch: false,
        ),
        onProgress: progress.add,
      );
      expect(id, 'p1');
      expect(range, 'bytes 0-299999/300000');
      expect(uploaded, 300000);
      expect(progress.last, 1.0);
    },
  );

  test('creator info parses options and limits', () {
    final info = TikTokCreatorInfo.fromJson({
      'creator_nickname': 'N',
      'creator_username': 'u',
      'privacy_level_options': ['FOLLOWER_OF_CREATOR', 'SELF_ONLY'],
      'comment_disabled': true,
      'max_video_post_duration_sec': 300,
    });
    expect(info.privacyOptions, ['FOLLOWER_OF_CREATOR', 'SELF_ONLY']);
    expect(info.commentDisabled, isTrue);
    expect(info.duetDisabled, isFalse);
    expect(info.maxDurationSeconds, 300);
  });

  test('post info turns allow flags into disable flags', () {
    const info = TikTokPostInfo(
      title: 'hi',
      privacyLevel: 'SELF_ONLY',
      allowComment: false,
      allowDuet: true,
      allowStitch: false,
      brandOrganic: true,
    );
    final json = info.toJson();
    expect(json['disable_comment'], isTrue);
    expect(json['disable_duet'], isFalse);
    expect(json['brand_organic_toggle'], isTrue);
    expect(json['brand_content_toggle'], isFalse);
  });

  test('errors map to user-facing kinds', () {
    expect(
      classifyTikTokError(
        const TikTokApiException(
          'unaudited_client_can_only_post_to_private_accounts',
        ),
      ),
      TikTokErrorKind.privateOnly,
    );
    expect(
      classifyTikTokError(const TikTokApiException('access_token_invalid')),
      TikTokErrorKind.authExpired,
    );
    expect(
      classifyTikTokError(const TikTokAuthException('cancelled')),
      TikTokErrorKind.cancelled,
    );
    expect(
      classifyTikTokError(const TikTokApiException('something_new')),
      TikTokErrorKind.unknown,
    );
    expect(
      TikTokApiException.fromBody(
        403,
        '{"error":{"code":"spam_risk_too_many_posts","message":"m","log_id":"x"}}',
      ).code,
      'spam_risk_too_many_posts',
    );
  });

  testWidgets('post stays disabled until a visibility is chosen', (
    tester,
  ) async {
    // Tall surface so the whole form (incl. the Post button) is built.
    await tester.binding.setSurfaceSize(const Size(420, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: TikTokUploadScreen(
          videoPath: '/nonexistent.mp4',
          auth: _FakeAuth(_session()),
          posts: _FakePosts(_creator),
        ),
      ),
    );
    await _settle(tester);

    expect(find.text('Gunny'), findsOneWidget);
    expect(find.text('Turned off in your TikTok settings'), findsOneWidget);
    final post = find.byKey(const Key('tiktok-post'));
    expect(tester.widget<FilledButton>(post).onPressed, isNull);

    await tester.tap(find.byKey(const Key('tiktok-privacy')));
    await _settle(tester);
    await tester.tap(find.text('Only me').last);
    await _settle(tester);

    expect(tester.widget<FilledButton>(post).onPressed, isNotNull);
  });
}
