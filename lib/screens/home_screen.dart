import 'dart:io';

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
  bool _projectsLoading = true;
  List<ProjectSummary> _projects = const [];

  @override
  void initState() {
    super.initState();
    _refreshYouTubeStatus();
    _loadProjects();
  }

  Future<void> _loadProjects() async {
    setState(() => _projectsLoading = true);
    final summaries = await _projectStorage.listSummaries();
    if (!mounted) return;
    setState(() {
      _projects = summaries;
      _projectsLoading = false;
    });
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
    await _loadProjects();
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

  Future<void> _deleteProject(ProjectSummary project) async {
    await _projectStorage.delete(project.id);
    await _loadProjects();
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

  String _projectTitle(ProjectSummary summary) {
    return DateFormat.yMMMd().add_jm().format(summary.updatedAt.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

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
              const SizedBox(height: 20),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Center(child: CircularProgressIndicator()),
                )
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
              const SizedBox(height: 28),
              Text(
                l10n.projectsSection,
                style: GoogleFonts.dmSans(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: _projectsLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _projects.isEmpty
                        ? Align(
                            alignment: Alignment.topLeft,
                            child: Text(
                              l10n.noProjectsYet,
                              style: GoogleFonts.dmSans(
                                fontSize: 14,
                                height: 1.45,
                                color: AppTheme.muted,
                              ),
                            ),
                          )
                        : ListView.separated(
                            itemCount: _projects.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 10),
                            itemBuilder: (context, index) {
                              final project = _projects[index];
                              return _ProjectTile(
                                title: _projectTitle(project),
                                subtitle: l10n.projectListSubtitle(
                                  project.overlayCount,
                                ),
                                enabled: !_loading,
                                onOpen: () => _openEditor(project.id),
                                onDelete: () => _deleteProject(project),
                                deleteTooltip: l10n.deleteProject,
                              );
                            },
                          ),
              ),
              const SizedBox(height: 12),
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

class _ProjectTile extends StatelessWidget {
  const _ProjectTile({
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onOpen,
    required this.onDelete,
    required this.deleteTooltip,
  });

  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback onOpen;
  final VoidCallback onDelete;
  final String deleteTooltip;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: AppTheme.muted.withValues(alpha: 0.25)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 6,
        ),
        leading: const Icon(Icons.movie_outlined),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              onPressed: enabled ? onDelete : null,
              icon: const Icon(Icons.delete_outline),
              tooltip: deleteTooltip,
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
        onTap: enabled ? onOpen : null,
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
