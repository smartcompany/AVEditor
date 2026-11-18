import 'package:aveditor/screens/editor_screen.dart';
import 'package:aveditor/services/retention_notification_service.dart';
import 'package:flutter/material.dart';

/// Root navigator + retention-push deep links.
class AppNavigator {
  AppNavigator._();

  static final key = GlobalKey<NavigatorState>();

  static NavigatorState? get state => key.currentState;

  /// Opens editor for a draft/share payload, or stays on home for catalog.
  static Future<void> handleRetentionPayload(String? payload) async {
    if (payload == null || payload.isEmpty) return;
    final nav = state;
    if (nav == null) return;

    if (payload == 'catalog') {
      // Home is enough — user can open gallery / transitions from there.
      nav.popUntil((route) => route.isFirst);
      return;
    }

    final projectId =
        RetentionNotificationService.projectIdFromPayload(payload);
    if (projectId == null || projectId.isEmpty) return;

    nav.popUntil((route) => route.isFirst);
    await nav.push(
      MaterialPageRoute<void>(
        builder: (_) => EditorScreen(projectId: projectId),
      ),
    );
  }
}
