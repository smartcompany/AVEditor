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
  static const _whatsappPackage = 'com.whatsapp';
  static const _facebookPackage = 'com.facebook.katana';

  /// Opens WhatsApp's chat picker with the video attached.
  /// Android sends the file; iOS shows WhatsApp's own "Open in" menu.
  Future<bool> shareToWhatsApp(String path) async {
    try {
      if (Platform.isAndroid) {
        if (await _sendToAndroidApp(path, _whatsappPackage)) return true;
      } else if (Platform.isIOS) {
        final shown = await _channel.invokeMethod<bool>('shareToWhatsApp', {
          'path': path,
        });
        if (shown == true) return true;
      }
    } catch (error, stack) {
      debugPrint('[ExportShare] WhatsApp 직접 공유 실패: $error\n$stack');
    }
    final uri = appUri(ShareTargetKind.whatsapp);
    return uri != null && await openApp(uri);
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
            '[ExportShare] Facebook status=$status source=${raw['source']}',
          );
          if (status != null && status != 'unavailable') {
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
      ShareTargetKind.whatsapp => Uri.parse('whatsapp://'),
      ShareTargetKind.youtube => null,
    };
  }
}
