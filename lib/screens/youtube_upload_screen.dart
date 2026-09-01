import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/services/app_settings_service.dart';
import 'package:aveditor/services/export_service.dart';
import 'package:aveditor/services/youtube_upload_service.dart';
import 'package:flutter/material.dart';

class YouTubeUploadScreen extends StatefulWidget {
  const YouTubeUploadScreen({super.key, required this.project});

  final VideoProject project;

  @override
  State<YouTubeUploadScreen> createState() => _YouTubeUploadScreenState();
}

class _YouTubeUploadScreenState extends State<YouTubeUploadScreen> {
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController(text: '#Shorts');
  String _privacy = 'public';
  bool _busy = false;

  final _export = ExportService();
  final _upload = YouTubeUploadService();
  final _settings = const AppSettingsService();

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = context.l10n;
    if (_titleController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.uploadTitleHint)),
      );
      return;
    }

    setState(() => _busy = true);
    try {
      final quality = await _settings.getExportQualityProfile();
      final path = await _export.exportForPreset(
        widget.project,
        quality: quality,
      );
      await _upload.uploadProject(
        project: widget.project,
        exportedPath: path,
        title: _titleController.text.trim(),
        description: _descriptionController.text.trim(),
        privacyStatus: _privacy,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.exportFailedWithMessage(e.toString())),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.uploadShorts)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          TextField(
            controller: _titleController,
            decoration: InputDecoration(labelText: l10n.uploadTitleHint),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _descriptionController,
            maxLines: 4,
            decoration: InputDecoration(labelText: l10n.uploadDescriptionHint),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _privacy,
            decoration: InputDecoration(labelText: l10n.uploadShorts),
            items: [
              DropdownMenuItem(value: 'public', child: Text(l10n.privacyPublic)),
              DropdownMenuItem(
                value: 'unlisted',
                child: Text(l10n.privacyUnlisted),
              ),
              DropdownMenuItem(
                value: 'private',
                child: Text(l10n.privacyPrivate),
              ),
            ],
            onChanged: _busy
                ? null
                : (v) {
                    if (v != null) setState(() => _privacy = v);
                  },
          ),
          const SizedBox(height: 32),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.uploadShorts),
          ),
        ],
      ),
    );
  }
}
