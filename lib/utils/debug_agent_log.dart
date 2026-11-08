import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Debug-mode NDJSON ingest (session 438ec3). Safe no-op on failure.
void debugAgentLog(
  String location,
  String message, {
  String hypothesisId = '',
  Map<String, Object?> data = const {},
  String runId = 'pre',
}) {
  // #region agent log
  final payload = <String, Object?>{
    'sessionId': '438ec3',
    'runId': runId,
    'hypothesisId': hypothesisId,
    'location': location,
    'message': message,
    'data': data,
    'timestamp': DateTime.now().millisecondsSinceEpoch,
  };
  debugPrint('[AVDbg] $location $message $data');
  () async {
    try {
      final hosts = <String>[
        if (Platform.isAndroid) '10.0.2.2',
        '127.0.0.1',
      ];
      for (final host in hosts) {
        try {
          final client = HttpClient();
          client.connectionTimeout = const Duration(milliseconds: 400);
          final req = await client.postUrl(
            Uri.parse(
              'http://$host:7428/ingest/b7abb55b-de33-4872-9dbf-922c26f0a415',
            ),
          );
          req.headers.set('Content-Type', 'application/json');
          req.headers.set('X-Debug-Session-Id', '438ec3');
          req.write(jsonEncode(payload));
          await req.close().timeout(const Duration(milliseconds: 600));
          client.close(force: true);
          return;
        } catch (_) {}
      }
    } catch (_) {}
  }();
  // #endregion
}
