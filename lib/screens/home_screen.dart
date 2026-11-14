import 'dart:io';

import 'package:aveditor/services/analytics_service.dart';
import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/screens/editor_screen.dart';
import 'package:aveditor/screens/settings_screen.dart';
import 'package:aveditor/services/project_storage_service.dart';
import 'package:aveditor/services/video_import_service.dart';
import 'package:aveditor/services/youtube_auth_service.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/widgets/convert_progress_view.dart';
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
  double? _convertProgress;
  bool _youtubeConnected = false;
  bool _projectsLoading = true;
  List<ProjectSummary> _projects = const [];

  /// Cover thumbnail lookups, keyed by project id + first-frame time so a
  /// trimmed project gets a fresh cover and others are not re-read.
  final Map<String, Future<String?>> _covers = {};

  Future<String?> _coverFor(ProjectSummary summary) {
    final key = '${summary.id}_${summary.coverTimeMs}';
    return _covers.putIfAbsent(
      key,
      () => _projectStorage.coverThumbnail(summary).catchError((_) => null),
    );
  }

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

  void _onConvertProgress(double value) {
    if (!mounted) return;
    final next = value.clamp(0.0, 1.0);
    final current = _convertProgress;
    if (current != null && (next - current).abs() < 0.01 && next < 1) return;
    setState(() => _convertProgress = next);
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
      final projectId = await _projectStorage.createFromImport(
        path,
        onProgress: _onConvertProgress,
      );
      AnalyticsService.instance.log('project_created');
      await _openEditor(projectId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.videoPickError(e.toString()))),
      );
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _convertProgress = null;
        });
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
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  String _projectTitle(ProjectSummary summary) {
    final name = summary.name?.trim();
    if (name != null && name.isNotEmpty) return name;
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
      body: DecoratedBox(
        decoration: AppTheme.ambientBackgroundDecoration(),
        child: SafeArea(
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
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: _convertProgress == null
                        ? const Center(child: CircularProgressIndicator())
                        : ConvertProgressView(
                            label: l10n.convertingVideo,
                            progress: _convertProgress!,
                          ),
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
                    color: AppTheme.ink,
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
                              cover: _coverFor(project),
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
      ),
    );
  }
}

class _ProjectTile extends StatelessWidget {
  const _ProjectTile({
    required this.cover,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onOpen,
    required this.onDelete,
    required this.deleteTooltip,
  });

  /// Path of the cover JPEG (first frame), or null when none could be made.
  final Future<String?> cover;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback onOpen;
  final VoidCallback onDelete;
  final String deleteTooltip;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onOpen : null,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.accent.withValues(alpha: 0.18)),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 4,
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.horizontal(
                      left: Radius.circular(16),
                    ),
                    gradient: AppTheme.brandGradient,
                  ),
                ),
                Expanded(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    leading: _ProjectCover(cover: cover),
                    title: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
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
                  ),
                ),
              ],
            ),
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
      children: [Icon(icon, size: 22), const SizedBox(width: 10), Text(label)],
    );

    if (outlined) {
      return OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppTheme.ink,
          side: BorderSide(color: AppTheme.accentCyan.withValues(alpha: 0.45)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: child,
      );
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          decoration: AppTheme.brandGradientDecoration(borderRadius: 12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: DefaultTextStyle(
              style: GoogleFonts.dmSans(
                color: AppTheme.ink,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
              child: IconTheme(
                data: const IconThemeData(color: AppTheme.ink, size: 22),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 9:16 cover of the project's first frame; the movie icon while loading or
/// when no frame could be read.
class _ProjectCover extends StatelessWidget {
  const _ProjectCover({required this.cover});

  final Future<String?> cover;

  static const _width = 40.0;
  static const _height = _width * 16 / 9;

  @override
  Widget build(BuildContext context) {
    final placeholder = Icon(
      Icons.movie_outlined,
      color: AppTheme.accentCyan.withValues(alpha: 0.9),
    );
    return SizedBox(
      width: _width,
      height: _height,
      child: FutureBuilder<String?>(
        future: cover,
        builder: (context, snapshot) {
          final path = snapshot.data;
          if (path == null) return Center(child: placeholder);
          return ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.file(
              File(path),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => Center(child: placeholder),
            ),
          );
        },
      ),
    );
  }
}
