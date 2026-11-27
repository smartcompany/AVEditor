import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/models/push_notification_category.dart';
import 'package:aveditor/services/app_settings_service.dart';
import 'package:aveditor/services/fcm_push_service.dart';
import 'package:aveditor/services/retention_notification_service.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Soft pre-permission: pick notification kinds, then (only if opted in)
/// request the OS alert permission. Shown as a centered popup on Home.
class NotificationPreferenceSheet extends StatefulWidget {
  const NotificationPreferenceSheet({super.key});

  /// Shows once when returning from the editor to Home. No-ops if already seen
  /// (also marked when the user changes Settings → Notifications).
  static Future<void> ensurePrompted(BuildContext context) async {
    final settings = const AppSettingsService();
    if (await settings.hasSeenNotificationPrefPrompt()) return;
    if (!context.mounted) return;

    // Wait one frame so the editor route is fully gone before presenting.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!context.mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      useRootNavigator: true,
      builder: (_) => const Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: NotificationPreferenceSheet(),
      ),
    );
    // Dismiss without a button → same as "Later".
    if (!await settings.hasSeenNotificationPrefPrompt()) {
      await settings.setNotificationMasterEnabled(false);
      await settings.setSeenNotificationPrefPrompt(true);
      await RetentionNotificationService.instance.applyPreferenceChange();
    }
  }

  @override
  State<NotificationPreferenceSheet> createState() =>
      _NotificationPreferenceSheetState();
}

class _NotificationPreferenceSheetState
    extends State<NotificationPreferenceSheet> {
  final _settings = const AppSettingsService();
  var _master = true;
  var _draft = true;
  var _share = true;
  var _catalog = true;
  var _busy = false;
  var _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final master = await _settings.getNotificationMasterEnabled();
    final draft = await _settings.getNotificationDraftEnabled();
    final share = await _settings.getNotificationShareEnabled();
    final catalog = await _settings.getNotificationCatalogEnabled();
    if (!mounted) return;
    setState(() {
      _master = master;
      _draft = draft;
      _share = share;
      _catalog = catalog;
      _loaded = true;
    });
  }

  Future<void> _finish({required bool allow}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (allow) {
        await _settings.setNotificationPreferences(
          master: _master,
          draft: _draft,
          share: _share,
          catalog: _catalog,
        );
        await _settings.setSeenNotificationPrefPrompt(true);
        if (_master) {
          await RetentionNotificationService.instance.requestPermissionIfNeeded();
          await FcmPushService.instance.syncRegistration();
        } else {
          await RetentionNotificationService.instance.applyPreferenceChange();
          await FcmPushService.instance.syncRegistration();
        }
      } else {
        // Defer: no OS dialog; keep categories but mute until Settings.
        await _settings.setNotificationPreferences(
          master: false,
          draft: _draft,
          share: _share,
          catalog: _catalog,
        );
        await _settings.setSeenNotificationPrefPrompt(true);
        await RetentionNotificationService.instance.applyPreferenceChange();
        await FcmPushService.instance.syncRegistration();
      }
    } finally {
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return Material(
      color: AppTheme.surfaceElevated,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 420,
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: !_loaded
              ? const SizedBox(
                  height: 220,
                  child: Center(child: CircularProgressIndicator()),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      l10n.notificationPrefSheetTitle,
                      style: GoogleFonts.dmSans(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.ink,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      l10n.notificationPrefSheetBody,
                      style: GoogleFonts.dmSans(
                        fontSize: 14,
                        height: 1.35,
                        color: AppTheme.muted,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _PrefTile(
                      icon: Icons.notifications_outlined,
                      gradient: true,
                      title: l10n.settingsNotificationsMasterTitle,
                      body: l10n.settingsNotificationsMasterBody,
                      value: _master,
                      onChanged: (v) => setState(() => _master = v),
                    ),
                    _PrefTile(
                      icon: Icons.edit_note_rounded,
                      title: l10n.settingsNotificationsDraftTitle,
                      body: l10n.settingsNotificationsDraftBody,
                      value: _draft,
                      enabled: _master,
                      onChanged: (v) => setState(() => _draft = v),
                    ),
                    _PrefTile(
                      icon: Icons.ios_share_rounded,
                      title: l10n.settingsNotificationsShareTitle,
                      body: l10n.settingsNotificationsShareBody,
                      value: _share,
                      enabled: _master,
                      onChanged: (v) => setState(() => _share = v),
                    ),
                    _PrefTile(
                      icon: Icons.auto_awesome_outlined,
                      title: l10n.settingsNotificationsCatalogTitle,
                      body: l10n.settingsNotificationsCatalogBody,
                      value: _catalog,
                      enabled: _master,
                      onChanged: (v) => setState(() => _catalog = v),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _busy ? null : () => _finish(allow: true),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.accent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: Text(
                        l10n.notificationPrefSheetAllow,
                        style: GoogleFonts.dmSans(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: _busy ? null : () => _finish(allow: false),
                      style: TextButton.styleFrom(
                        foregroundColor: AppTheme.muted,
                      ),
                      child: Text(l10n.notificationPrefSheetLater),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _PrefTile extends StatelessWidget {
  const _PrefTile({
    required this.icon,
    required this.title,
    required this.body,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.gradient = false,
  });

  final IconData icon;
  final String title;
  final String body;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;
  final bool gradient;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 40,
                height: 40,
                child: DecoratedBox(
                  decoration: gradient
                      ? AppTheme.brandGradientDecoration(borderRadius: 12)
                      : BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: Colors.white.withValues(alpha: 0.06),
                          border: Border.all(
                            color: AppTheme.muted.withValues(alpha: 0.2),
                          ),
                        ),
                  child: Icon(
                    icon,
                    size: 20,
                    color: Colors.white.withValues(alpha: 0.95),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.dmSans(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: AppTheme.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    body,
                    style: GoogleFonts.dmSans(
                      fontSize: 12,
                      height: 1.3,
                      color: AppTheme.muted,
                    ),
                  ),
                ],
              ),
            ),
            Switch.adaptive(
              value: value,
              activeThumbColor: AppTheme.accent,
              onChanged: enabled ? onChanged : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// Marks the soft prompt as done so Settings edits don't re-trigger it.
Future<void> markNotificationPrefPromptSeen() {
  return const AppSettingsService().setSeenNotificationPrefPrompt(true);
}

/// Used by Settings when the user changes a notification toggle.
Future<void> syncNotificationPreferenceFromSettings({
  PushNotificationCategory? cancelledCategory,
  required bool requestOsIfEnabling,
  required bool enabling,
}) async {
  await markNotificationPrefPromptSeen();
  if (!enabling) {
    await RetentionNotificationService.instance.applyPreferenceChange(
      category: cancelledCategory,
    );
    return;
  }
  if (requestOsIfEnabling) {
    await RetentionNotificationService.instance.requestPermissionIfNeeded();
  }
  await FcmPushService.instance.syncRegistration();
}
