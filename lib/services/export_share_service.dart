import 'package:aveditor/services/share_catalog_service.dart';
import 'package:flutter/foundation.dart';
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

  Future<void> shareFile(String path) {
    return Share.shareXFiles([XFile(path)]);
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
