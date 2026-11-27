import 'dart:io';
import 'dart:math' as math;

import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/navigation/editor_route.dart';
import 'package:aveditor/screens/export_share_screen.dart';
import 'package:aveditor/screens/settings_screen.dart';
import 'package:aveditor/services/analytics_service.dart';
import 'package:aveditor/services/export_share_service.dart';
import 'package:aveditor/services/media_pick_batch.dart';
import 'package:aveditor/services/project_storage_service.dart';
import 'package:aveditor/services/retention_notification_service.dart';
import 'package:aveditor/services/video_import_service.dart';
import 'package:aveditor/theme/app_theme.dart';
import 'package:aveditor/utils/logged_snackbar.dart';
import 'package:aveditor/utils/platform_helper.dart';
import 'package:aveditor/widgets/convert_progress_view.dart';
import 'package:aveditor/widgets/notification_preference_sheet.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _appShareUrl = 'https://easyclip.coinpang.org';
  static const _danger = Color(0xFFE53935);

  final _import = VideoImportService();
  final _projectStorage = const ProjectStorageService();
  final _share = ExportShareService();
  bool _loading = false;
  double? _convertProgress;
  bool _projectsLoading = true;
  String? _openingProjectId;
  List<ProjectSummary> _projects = const [];
  bool _selecting = false;
  final Set<String> _selectedIds = {};

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
    _loadProjects();
  }

  Future<void> _loadProjects() async {
    setState(() => _projectsLoading = true);
    final summaries = await _projectStorage.listSummaries();
    if (!mounted) return;
    setState(() {
      _projects = summaries;
      _projectsLoading = false;
      _selectedIds.removeWhere(
        (id) => !summaries.any((p) => p.id == id),
      );
      if (_selecting && summaries.isEmpty) {
        _selecting = false;
        _selectedIds.clear();
      }
    });
  }

  void _toggleSelecting() {
    setState(() {
      _selecting = !_selecting;
      if (!_selecting) _selectedIds.clear();
    });
  }

  void _toggleSelected(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  Future<void> _openEditor(String projectId) async {
    if (!mounted || _openingProjectId != null) return;
    setState(() => _openingProjectId = projectId);
    try {
      await Navigator.of(context).push(
        editorRoute(
          projectId,
          onReady: () {
            if (!mounted) return;
            if (_openingProjectId == projectId) {
              setState(() => _openingProjectId = null);
            }
          },
        ),
      );
    } finally {
      if (mounted && _openingProjectId == projectId) {
        setState(() => _openingProjectId = null);
      }
      await _loadProjects();
    }
    // Soft notification prefs: after first return from the editor to Home
    // (never before the soft popup — draft scheduling waits for this).
    if (!mounted) return;
    await NotificationPreferenceSheet.ensurePrompted(context);
    if (!mounted) return;
    final l10n = context.l10n;
    await RetentionNotificationService.instance.flushPendingDraftAbandon(
      title: l10n.pushDraftTitle,
      body24: l10n.pushDraftBody24,
      body72: l10n.pushDraftBody72,
    );
  }

  Future<void> _pickGallery() async {
    await _runPickBatch(() => _import.pickFromGallery(context));
  }

  Future<void> _openShareMyContent() async {
    if (!mounted || _loading) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const ExportShareScreen.pickFromAlbum(),
      ),
    );
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

  Future<void> _runPickBatch(Future<MediaPickBatch> Function() pick) async {
    try {
      final batch = await pick();
      if (batch.isEmpty) return;
      await _createProjectFromPaths(
        batch.paths,
        imageHoldDuration: batch.imageHoldDuration,
      );
    } catch (e, st) {
      if (!mounted) return;
      final detail = e.toString();
      final message = detail.contains('empty_video')
          ? context.l10n.videoPickEmpty
          : context.l10n.videoPickError(detail);
      showLoggedSnackBar(context, message, error: e, stackTrace: st);
    }
  }

  Future<void> _runPick(Future<List<String>> Function() pick) async {
    try {
      final paths = await pick();
      if (paths.isEmpty) return;
      await _createProjectFromPaths(paths);
    } catch (e, st) {
      if (!mounted) return;
      final detail = e.toString();
      final message = detail.contains('empty_video')
          ? context.l10n.videoPickEmpty
          : context.l10n.videoPickError(detail);
      showLoggedSnackBar(context, message, error: e, stackTrace: st);
    }
  }

  Future<void> _createProjectFromPaths(
    List<String> paths, {
    Duration? imageHoldDuration,
  }) async {
    try {
      for (final path in paths) {
        if (!File(path).existsSync()) {
          throw StateError('file not found');
        }
      }
      // Show progress only after files are chosen — not while the gallery is open.
      if (!mounted) return;
      setState(() {
        _loading = true;
        _convertProgress = null;
      });
      final projectId = await _projectStorage.createFromImports(
        paths,
        imageHoldDuration: imageHoldDuration,
        onProgress: _onConvertProgress,
      );
      AnalyticsService.instance.log('project_created');
      await _openEditor(projectId);
    } catch (e, st) {
      if (!mounted) return;
      final detail = e.toString();
      final message = detail.contains('empty_video')
          ? context.l10n.videoPickEmpty
          : context.l10n.videoPickError(detail);
      showLoggedSnackBar(context, message, error: e, stackTrace: st);
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _convertProgress = null;
        });
      }
    }
  }

  Future<bool> _confirmDelete({required int count}) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(l10n.deleteProject),
          content: Text(
            count == 1
                ? l10n.deleteProjectConfirm
                : l10n.deleteProjectsConfirm(count),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(l10n.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(l10n.deleteSelected),
            ),
          ],
        );
      },
    );
    return confirmed == true;
  }

  Future<void> _deleteProject(ProjectSummary project) async {
    final ok = await _confirmDelete(count: 1);
    if (!mounted || !ok) return;
    await _projectStorage.delete(project.id);
    await _loadProjects();
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final ids = List<String>.from(_selectedIds);
    final ok = await _confirmDelete(count: ids.length);
    if (!mounted || !ok) return;
    for (final id in ids) {
      await _projectStorage.delete(id);
    }
    if (!mounted) return;
    setState(() {
      _selecting = false;
      _selectedIds.clear();
    });
    await _loadProjects();
  }

  String _projectTitle(ProjectSummary summary) {
    final name = summary.name?.trim();
    if (name != null && name.isNotEmpty) return name;
    return DateFormat.yMMMd().add_jm().format(summary.updatedAt.toLocal());
  }

  Future<void> _shareApp() async {
    final text = context.l10n.shareAppMessage(_appShareUrl);
    AnalyticsService.instance.log('share_app');
    await _share.shareText(text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final showProjectsHeader = _projectsLoading || _projects.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appTitle),
        actions: [
          IconButton(
            onPressed: _loading ? null : _shareApp,
            icon: const Icon(Icons.ios_share_outlined),
            tooltip: l10n.share,
          ),
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
                if (_loading)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: ConvertProgressView(
                      label: _convertProgress == null
                          ? l10n.openingVideo
                          : l10n.convertingVideo,
                      progress: _convertProgress,
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
                  if (PlatformHelper.supportsGallery) ...[
                    const SizedBox(height: 12),
                    _ActionButton(
                      icon: Icons.ios_share_outlined,
                      label: l10n.shareMyContent,
                      onPressed: _openShareMyContent,
                      outlined: true,
                    ),
                  ],
                ],
                if (showProjectsHeader) ...[
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.projectsSection,
                          style: GoogleFonts.dmSans(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.ink,
                          ),
                        ),
                      ),
                      if (!_projectsLoading && _projects.isNotEmpty)
                        TextButton(
                          onPressed: _loading ? null : _toggleSelecting,
                          child: Text(
                            _selecting ? l10n.projectsDone : l10n.projectsEdit,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],
                Expanded(
                  child: _projectsLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _projects.isEmpty
                      ? const SizedBox.shrink()
                      : ListView(
                          children: [
                            for (var i = 0; i < _projects.length; i++) ...[
                              if (i > 0) const SizedBox(height: 10),
                              Builder(
                                builder: (context) {
                                  final project = _projects[i];
                                  final selected =
                                      _selectedIds.contains(project.id);
                                  return _SwipeToDelete(
                                    enabled: !_selecting &&
                                        !_loading &&
                                        _openingProjectId == null,
                                    deleteLabel: l10n.deleteSelected,
                                    onDelete: () => _deleteProject(project),
                                    child: _ProjectTile(
                                      cover: _coverFor(project),
                                      title: _projectTitle(project),
                                      opening:
                                          _openingProjectId == project.id,
                                      enabled: !_loading &&
                                          _openingProjectId == null,
                                      selecting: _selecting,
                                      selected: selected,
                                      onOpen: () {
                                        if (_selecting) {
                                          _toggleSelected(project.id);
                                        } else {
                                          _openEditor(project.id);
                                        }
                                      },
                                      onToggleSelect: () =>
                                          _toggleSelected(project.id),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ],
                        ),
                ),
                if (_selecting && _projects.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: FilledButton.icon(
                      onPressed: _selectedIds.isEmpty || _loading
                          ? null
                          : _deleteSelected,
                      icon: const Icon(Icons.delete_outline),
                      label: Text(
                        _selectedIds.isEmpty
                            ? l10n.deleteSelected
                            : '${l10n.deleteSelected} (${_selectedIds.length})',
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: _danger,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor:
                            _danger.withValues(alpha: 0.35),
                        padding: const EdgeInsets.symmetric(vertical: 14),
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

/// Swipe left to reveal a delete action (iOS-style).
class _SwipeToDelete extends StatefulWidget {
  const _SwipeToDelete({
    required this.child,
    required this.onDelete,
    required this.deleteLabel,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback onDelete;
  final String deleteLabel;
  final bool enabled;

  @override
  State<_SwipeToDelete> createState() => _SwipeToDeleteState();
}

class _SwipeToDeleteState extends State<_SwipeToDelete>
    with SingleTickerProviderStateMixin {
  static const _actionWidth = 88.0;
  static const _danger = Color(0xFFE53935);

  late final AnimationController _controller;
  double _dragExtent = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      upperBound: _actionWidth,
    )..addListener(() {
        setState(() => _dragExtent = _controller.value);
      });
  }

  @override
  void didUpdateWidget(covariant _SwipeToDelete oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _dragExtent != 0) {
      _controller.animateTo(0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!widget.enabled) return;
    final next = (_dragExtent - details.delta.dx).clamp(0.0, _actionWidth);
    _controller.value = next;
  }

  void _onDragEnd(DragEndDetails details) {
    if (!widget.enabled) return;
    final velocity = details.primaryVelocity ?? 0;
    final open = velocity < -300 ||
        (velocity <= 300 && _dragExtent > _actionWidth / 2);
    _controller.animateTo(open ? _actionWidth : 0);
  }

  @override
  Widget build(BuildContext context) {
    final openFraction =
        _actionWidth == 0 ? 0.0 : (_dragExtent / _actionWidth).clamp(0.0, 1.0);

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        children: [
          Positioned.fill(
            child: Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: math.max(_dragExtent, 0.001),
                child: Material(
                  color: _danger,
                  child: InkWell(
                    onTap: openFraction > 0.85
                        ? () {
                            _controller.animateTo(0);
                            widget.onDelete();
                          }
                        : null,
                    child: Opacity(
                      opacity: openFraction,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.delete_outline,
                              color: Colors.white,
                              size: 22,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.deleteLabel,
                              style: GoogleFonts.dmSans(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          GestureDetector(
            onHorizontalDragUpdate: widget.enabled ? _onDragUpdate : null,
            onHorizontalDragEnd: widget.enabled ? _onDragEnd : null,
            child: Transform.translate(
              offset: Offset(-_dragExtent, 0),
              child: widget.child,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProjectTile extends StatelessWidget {
  const _ProjectTile({
    required this.cover,
    required this.title,
    required this.enabled,
    required this.onOpen,
    required this.selecting,
    required this.selected,
    required this.onToggleSelect,
    this.opening = false,
  });

  /// Path of the cover JPEG (first frame), or null when none could be made.
  final Future<String?> cover;
  final String title;
  final bool opening;
  final bool enabled;
  final bool selecting;
  final bool selected;
  final VoidCallback onOpen;
  final VoidCallback onToggleSelect;

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
            border: Border.all(
              color: selected
                  ? AppTheme.accent.withValues(alpha: 0.55)
                  : opening
                  ? AppTheme.accent.withValues(alpha: 0.45)
                  : AppTheme.accent.withValues(alpha: 0.18),
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: IntrinsicHeight(
              child: Stack(
                children: [
                  Row(
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
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: selecting
                              ? Checkbox(
                                  value: selected,
                                  onChanged: enabled
                                      ? (_) => onToggleSelect()
                                      : null,
                                  activeColor: AppTheme.accent,
                                )
                              : const Icon(Icons.chevron_right),
                        ),
                      ),
                    ],
                  ),
                  if (opening)
                    const Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        minHeight: 3,
                        backgroundColor: Color(0x22FFFFFF),
                        color: AppTheme.accent,
                      ),
                    ),
                ],
              ),
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
