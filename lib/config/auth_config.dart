import 'dart:io' show Platform;

import 'package:aveditor/theme/app_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:share_lib/share_lib_auth.dart';

/// Kakao native app key (optional until Console keys are wired).
const kakaoNativeAppKey = String.fromEnvironment(
  'KAKAO_NATIVE_APP_KEY',
  defaultValue: '',
);

final AuthConfig easyClipAuthConfig = AuthConfig(
  primaryColor: AppTheme.accent,
  backgroundColor: AppTheme.surface,
  textPrimaryColor: const Color(0xFFF5F0F8),
  textSecondaryColor: AppTheme.muted,
  enableGoogleLogin: true,
  enableKakaoLogin: kakaoNativeAppKey.isNotEmpty,
  enableAppleLogin: !kIsWeb && Platform.isIOS,
  enableEmailLogin: false,
  shouldShowProfileSetup: null,
  profileSetupScreenBuilder: null,
);
