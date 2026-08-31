import 'dart:io';

class PlatformHelper {
  static bool get isMobile => Platform.isIOS || Platform.isAndroid;

  static bool get isDesktop => Platform.isMacOS;

  static bool get supportsCamera => isMobile;

  static bool get supportsGallery => isMobile;

  static bool get supportsFilePicker => Platform.isMacOS || Platform.isAndroid;
}
