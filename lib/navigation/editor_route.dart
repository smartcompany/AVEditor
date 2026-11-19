import 'package:aveditor/screens/editor_screen.dart';
import 'package:flutter/material.dart';

/// Opens the editor without covering the previous screen until it is ready.
///
/// While [EditorScreen] loads, the route is transparent so Home stays visible.
Route<void> editorRoute(
  String projectId, {
  VoidCallback? onReady,
}) {
  return PageRouteBuilder<void>(
    opaque: false,
    barrierDismissible: false,
    pageBuilder: (context, animation, secondaryAnimation) {
      return EditorScreen(projectId: projectId, onReady: onReady);
    },
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      // Instant once ready — no blank interstitial page.
      return child;
    },
  );
}
