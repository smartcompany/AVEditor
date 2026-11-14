import 'dart:io';

import 'package:aveditor/services/share_catalog_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens a saved video in another app, or the system share sheet.
class ExportShareService {
  Future<bool> openApp(Uri uri) async {
    try {
      final supported = await canLaunchUrl(uri);
      if (!supported) return false;
      return launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (error, stack) {
      debugPrint('[ExportShare] 앱 열기 실패: $error\n$stack');
      return false;
    }
  }

  static const _channel = MethodChannel('aveditor/media_share');

  /// Opens Instagram with the exported video already selected.
  /// iOS uses the Photos asset id from the album save; Android sends the file.
  /// Falls back to just opening Instagram. False when Instagram is missing.
  Future<bool> shareToInstagram({
    required String path,
    String? photosAssetId,
  }) async {
    try {
      if (Platform.isAndroid) {
        if (await _sendToAndroidApp(path, _instagramPackage)) return true;
      } else if (Platform.isIOS && photosAssetId != null) {
        final opened = await _channel.invokeMethod<bool>('openInstagram', {
          'localIdentifier': photosAssetId,
        });
        if (opened == true) return true;
      }
    } catch (error, stack) {
      debugPrint('[ExportShare] Instagram 직접 공유 실패: $error\n$stack');
    }
    final uri = appUri(ShareTargetKind.instagram);
    return uri != null && await openApp(uri);
  }

  static const _instagramPackage = 'com.instagram.android';
  static const _facebookPackage = 'com.facebook.katana';

  /// TikTok (US / most regions) and TikTok (alternate package).
  static const _tiktokPackages = [
    'com.zhiliaoapp.musically',
    'com.ss.android.ugc.trill',
  ];

  /// Opens TikTok's upload flow with the video attached.
  /// Android: ACTION_SEND to the TikTok package.
  /// iOS: TikTok Share Kit when client key is set; otherwise shares the file
  /// so the user can pick TikTok (plain app open cannot attach media).
  Future<bool> shareToTikTok(String path, {String? photosAssetId}) async {
    try {
      if (Platform.isAndroid) {
        for (final pkg in _tiktokPackages) {
          if (await _sendToAndroidApp(path, pkg)) return true;
        }
        return false;
      }
      if (Platform.isIOS) {
        // Native replies {status: posted|cancelled|failed|sheet|unavailable}
        // once TikTok returns, or right away for sheet / unavailable.
        final raw = await _channel.invokeMethod<dynamic>('shareToTikTok', {
          'path': path,
          'localIdentifier': ?photosAssetId,
        });
        if (raw is! Map) return raw == true;
        final status = raw['status']?.toString();
        debugPrint(
          '[ExportShare] TikTok status=$status message=${raw['message']}',
        );
        if (status == 'posted' || status == 'cancelled' || status == 'failed') {
          onTikTokResult?.call(status!, raw['message']?.toString());
        }
        return status != null && status != 'unavailable';
      }
    } catch (error, stack) {
      debugPrint('[ExportShare] TikTok 직접 공유 실패: $error\n$stack');
    }
    return false;
  }

  /// Opens Facebook's composer with the video attached.
  /// Android sends the file to the Facebook app. iOS uses the Facebook SDK
  /// share dialog once the app id is configured, else the system share sheet.
  Future<bool> shareToFacebook(String path, {String? photosAssetId}) async {
    if (Platform.isAndroid) {
      try {
        if (await _sendToAndroidApp(path, _facebookPackage)) return true;
      } catch (error, stack) {
        debugPrint('[ExportShare] Facebook 직접 공유 실패: $error\n$stack');
      }
      return false;
    }
    if (Platform.isIOS) {
      try {
        // Native replies with {status: posted|cancelled|failed|unavailable}.
        final raw = await _channel.invokeMethod<dynamic>('shareToFacebook', {
          'path': path,
          'localIdentifier': ?photosAssetId,
        });
        if (raw is Map) {
          final status = raw['status']?.toString();
          debugPrint(
            '[ExportShare] Facebook status=$status source=${raw['source']} '
            'message=${raw['message']}',
          );
          if (status != null && status != 'unavailable') {
            onFacebookResult?.call(status, raw['message']?.toString());
            return true;
          }
        } else if (raw == true) {
          return true;
        }
      } catch (error, stack) {
        debugPrint('[ExportShare] Facebook 직접 공유 실패: $error\n$stack');
      }
    }
    await shareFile(path);
    return true;
  }

  /// Called with "posted" / "cancelled" / "failed" (+ message) after TikTok
  /// Share Kit returns to the app (iOS).
  void Function(String status, String? message)? onTikTokResult;

  /// Called with "posted" / "cancelled" / "failed" (+ message) after the
  /// iOS Facebook share dialog returns to the app.
  void Function(String status, String? message)? onFacebookResult;

  Future<bool> _sendToAndroidApp(String path, String package) async {
    final sent = await _channel.invokeMethod<bool>('shareVideoToApp', {
      'path': path,
      'package': package,
    });
    return sent == true;
  }

  /// Share sheet with plain text (e.g. the uploaded Shorts link).
  Future<void> shareText(String text) async {
    if (Platform.isIOS) {
      try {
        final shown = await _channel.invokeMethod<bool>('shareFile', {
          'text': text,
        });
        if (shown == true) return;
      } catch (error, stack) {
        debugPrint('[ExportShare] 공유 시트 실패: $error\n$stack');
      }
    }
    await Share.share(text);
  }

  Future<void> shareFile(String path) async {
    if (Platform.isIOS) {
      try {
        final shown = await _channel.invokeMethod<bool>('shareFile', {
          'path': path,
        });
        if (shown == true) return;
      } catch (error, stack) {
        debugPrint('[ExportShare] 공유 시트 실패: $error\n$stack');
      }
    }
    await Share.shareXFiles([XFile(path)]);
  }

  Uri? appUri(ShareTargetKind kind) {
    return switch (kind) {
      ShareTargetKind.instagram => Uri.parse('instagram://app'),
      ShareTargetKind.facebook => Uri.parse('fb://'),
      ShareTargetKind.tiktok => Uri.parse('snssdk1233://'),
      ShareTargetKind.youtube => null,
    };
  }
}
