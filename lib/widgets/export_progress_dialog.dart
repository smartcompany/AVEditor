import 'package:aveditor/l10n/l10n_extensions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class ExportProgressDialog extends StatelessWidget {
  const ExportProgressDialog({
    super.key,
    required this.progressListenable,
  });

  final ValueListenable<double> progressListenable;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return AlertDialog(
      title: Text(l10n.exporting),
      content: ValueListenableBuilder<double>(
        valueListenable: progressListenable,
        builder: (context, progress, _) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LinearProgressIndicator(value: progress.clamp(0.0, 1.0)),
              const SizedBox(height: 12),
              Text(
                '${(progress * 100).round()}%',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          );
        },
      ),
    );
  }
}
