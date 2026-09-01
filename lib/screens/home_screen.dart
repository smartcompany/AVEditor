import 'dart:io';

import 'package:aveditor/l10n/app_localizations.dart';
import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/screens/editor_screen.dart';
import 'package:aveditor/screens/settings_screen.dart';
import 'package:aveditor/services/project_storage_service.dart';
import 'package:aveditor/services/video_import_service.dart';
import 'package:aveditor/services/youtube_auth_service.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/utils/platform_helper.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _import = VideoImportService();
  final _projectStorage = const ProjectStorageService();
  final _youtubeAuth = YouTubeAuthService();
  bool _loading = false;
  bool _youtubeConnected = false;
  ProjectSummary? _resumeProject;

  @override
  void initState() {
    super.initState();
    _refreshYouTubeStatus();
    _loadResumeProject();
  }

  Future<void> _loadResumeProject() async {
    final summary = await _projectStorage.loadLastSummary();
    if (!mounted) return;
    setState(() => _resumeProject = summary);
  }

  Future<void> _refreshYouTubeStatus() async {
    final signedIn = await _youtubeAuth.isSignedIn;
    if (mounted) {
      setState(() => _youtubeConnected = signedIn);
    }
  }

  Future<void> _openEditor(String projectId) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EditorScreen(projectId: projectId),
      ),
    );
    await _loadResumeProject();
  }

  Future<void> _resumeLastProject() async {
    final summary = _resumeProject;
    if (summary == null || !summary.sourceExists) return;
    await _openEditor(summary.id);
  }

  Future<void> _pickGallery() async {
    await _runPick(_import.pickFromGallery);
  }

  Future<void> _pickFiles() async {
    await _runPick(_import.pickFromFiles);
  }

  Future<void> _pickCamera() async {
    await _runPick(_import.pickFromCamera);
  }

  Future<void> _runPick(Future<String?> Function() pick) async {
    setState(() => _loading = true);
    try {
      final path = await pick();
      if (path == null || path.isEmpty) {
        return;
      }
      if (!File(path).existsSync()) {
        throw StateError('file not found');
      }
      final projectId = await _projectStorage.createFromImport(path);
      await _openEditor(projectId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.videoPickError(e.toString())),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _toggleYouTube() async {
    if (_youtubeConnected) {
      await _youtubeAuth.signOut();
      await _refreshYouTubeStatus();
      return;
    }

    try {
      await _youtubeAuth.signIn();
      await _refreshYouTubeStatus();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.comingSoon)),
      );
    }
  }

  String _resumeSubtitle(ProjectSummary summary, AppLocalizations l10n) {
    final updated = DateFormat.yMMMd().add_jm().format(summary.updatedAt.toLocal());
    return l10n.resumeEditingSubtitle(
      summary.overlayCount,
      updated,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final resume = _resumeProject;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appTitle),
        actions: [
          IconButton(
            onPressed: _loading
                ? null
                : () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SettingsScreen(),
                      ),
                    );
                  },
            icon: const Icon(Icons.settings_outlined),
            tooltip: l10n.settingsTitle,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Text(
                l10n.homeTagline,
                style: GoogleFonts.dmSans(
                  fontSize: 15,
                  height: 1.5,
                  color: AppTheme.muted,
                ),
              ),
              if (resume != null && resume.sourceExists) ...[
                const SizedBox(height: 20),
                Card(
                  elevation: 0,
                  color: AppTheme.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: AppTheme.muted.withValues(alpha: 0.25)),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    leading: const Icon(Icons.history_rounded),
                    title: Text(l10n.resumeEditing),
                    subtitle: Text(_resumeSubtitle(resume, l10n)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _loading ? null : _resumeLastProject,
                  ),
                ),
              ],
              const Spacer(),
              if (_loading)
                const Center(child: CircularProgressIndicator())
              else ...[
                if (PlatformHelper.supportsGallery)
                  _ActionButton(
                    icon: Icons.photo_library_outlined,
                    label: l10n.pickFromGallery,
                    onPressed: _pickGallery,
                  ),
                if (PlatformHelper.supportsFilePicker) ...[
                  const SizedBox(height: 12),
                  _ActionButton(
                    icon: Icons.folder_open_outlined,
                    label: l10n.pickFromFiles,
                    onPressed: _pickFiles,
                    outlined: true,
                  ),
                ],
                if (PlatformHelper.supportsCamera) ...[
                  const SizedBox(height: 12),
                  _ActionButton(
                    icon: Icons.videocam_outlined,
                    label: l10n.recordVideo,
                    onPressed: _pickCamera,
                    outlined: true,
                  ),
                ],
              ],
              const Spacer(flex: 2),
              OutlinedButton.icon(
                onPressed: _toggleYouTube,
                icon: Icon(
                  _youtubeConnected
                      ? Icons.check_circle_outline
                      : Icons.play_circle_outline,
                ),
                label: Text(
                  _youtubeConnected
                      ? l10n.youtubeSignedIn
                      : l10n.youtubeSignIn,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.outlined = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final child = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 22),
        const SizedBox(width: 10),
        Text(label),
      ],
    );

    if (outlined) {
      return OutlinedButton(onPressed: onPressed, child: child);
    }
    return FilledButton(onPressed: onPressed, child: child);
  }
}
