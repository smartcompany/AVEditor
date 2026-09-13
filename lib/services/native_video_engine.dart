import 'dart:async';
import 'dart:io';

import 'package:aveditor/models/applied_transition.dart';
import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/services/transition_engine.dart';
import 'package:aveditor/utils/clip_segment_ops.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Flutter ↔ platform [Native Video Engine] bridge.
///
/// ```
/// Flutter
///   ├── Timeline UI
///   ├── Clip / Transition data
///   └── Native Bridge  (this class)
///          ├── iOS: AVFoundation + Metal
///          └── Android: Media3 + GPU Renderer
/// ```
///
/// Opacity fades stay on the Flutter dual-[VideoPlayer] path.
class NativeVideoEngine {
  NativeVideoEngine._();

  static final NativeVideoEngine instance = NativeVideoEngine._();

  static const _channel =
      MethodChannel('com.smart.aveditor/native_video_engine');
  static const _events =
      EventChannel('com.smart.aveditor/native_video_engine/events');

  static const _opacityOnlyXfades = {
    'fade',
    'dissolve',
    'fadeblack',
    'fadewhite',
  };

  /// Slide / push conveyor effects implemented in the native GPU path.
  static const supportedEffects = {
    'slideleft',
    'slideright',
    'slideup',
    'slidedown',
    'coverleft',
    'coverright',
    'coverup',
    'coverdown',
    'pushleft',
    'pushright',
    'pushup',
    'pushdown',
  };

  int? _textureId;
  StreamSubscription<dynamic>? _eventSub;
  final _positionController = StreamController<Duration>.broadcast();
  final _playingController = StreamController<bool>.broadcast();
  var _active = false;
  var _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  int? get textureId => _textureId;
  bool get isActive => _active;
  bool get isPlaying => _playing;
  Duration get position => _position;
  Duration get duration => _duration;
  Stream<Duration> get positionStream => _positionController.stream;
  Stream<bool> get playingStream => _playingController.stream;

  bool get isPlatformSupported =>
      !kIsWeb && (Platform.isIOS || Platform.isAndroid);

  /// Non-opacity transition (candidate for native engine).
  static bool isSpatialPreview(AppliedTransition? applied) {
    if (applied == null || applied.isNone) return false;
    final name =
        TransitionEngine.instance.ffmpegNameFor(applied)?.toLowerCase();
    if (name == null || name.isEmpty) return false;
    return !_opacityOnlyXfades.contains(name);
  }

  /// Native GPU preview for these effects. Disabled until the Flutter Texture
  /// path reliably delivers frames (was showing a black preview surface).
  /// Spatial cuts use the Flutter dual-layer conveyor instead; native remains
  /// for probe / waveform / export.
  static bool supports(AppliedTransition? applied) => false;

  Future<int?> prepareTransition({
    required String sourcePath,
    required ClipSegment outgoing,
    required ClipSegment incoming,
    required AppliedTransition transition,
  }) async {
    if (!supports(transition)) return null;

    final td = clampedTransitionDuration(outgoing, next: incoming);
    if (td <= Duration.zero) return null;

    final effect =
        TransitionEngine.instance.ffmpegNameFor(transition)?.toLowerCase();
    if (effect == null) return null;

    await dispose();

    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'prepareTransition',
        {
          'sourcePath': sourcePath,
          'outgoingStartMs': (outgoing.end - td).inMilliseconds,
          'outgoingEndMs': outgoing.end.inMilliseconds,
          'incomingStartMs': incoming.start.inMilliseconds,
          'incomingEndMs': (incoming.start + td).inMilliseconds,
          'durationMs': td.inMilliseconds,
          'effect': effect,
        },
      );
      if (result == null) return null;

      final textureId = result['textureId'] as int?;
      final durationMs = result['durationMs'] as int? ?? td.inMilliseconds;
      if (textureId == null) return null;

      _textureId = textureId;
      _duration = Duration(milliseconds: durationMs);
      _position = Duration.zero;
      _active = true;
      _playing = false;
      _ensureEventListening();
      return textureId;
    } on PlatformException catch (e, st) {
      if (kDebugMode) {
        debugPrint('NativeVideoEngine.prepareTransition failed: $e\n$st');
      }
      await dispose();
      return null;
    }
  }

  Future<void> play() async {
    if (!_active) return;
    await _channel.invokeMethod<void>('play');
    _playing = true;
    if (!_playingController.isClosed) _playingController.add(true);
  }

  Future<void> pause() async {
    if (!_active) return;
    await _channel.invokeMethod<void>('pause');
    _playing = false;
    if (!_playingController.isClosed) _playingController.add(false);
  }

  Future<void> seek(Duration position) async {
    if (!_active) return;
    final ms = position.inMilliseconds.clamp(0, _duration.inMilliseconds);
    await _channel.invokeMethod<void>('seek', {'positionMs': ms});
    _position = Duration(milliseconds: ms);
    if (!_positionController.isClosed) _positionController.add(_position);
  }

  Future<void> dispose() async {
    if (_active || _textureId != null) {
      try {
        await _channel.invokeMethod<void>('dispose');
      } catch (_) {}
    }
    _textureId = null;
    _active = false;
    _playing = false;
    _position = Duration.zero;
    _duration = Duration.zero;
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    final map = Map<String, dynamic>.from(event);
    switch (map['type'] as String?) {
      case 'position':
        final ms = map['positionMs'] as int? ?? 0;
        _position = Duration(milliseconds: ms);
        if (!_positionController.isClosed) _positionController.add(_position);
      case 'playing':
        _playing = map['playing'] as bool? ?? false;
        if (!_playingController.isClosed) _playingController.add(_playing);
      case 'completed':
        _playing = false;
        _position = _duration;
        if (!_playingController.isClosed) _playingController.add(false);
        if (!_positionController.isClosed) _positionController.add(_position);
      case 'exportProgress':
        final p = (map['progress'] as num?)?.toDouble() ?? 0;
        _exportProgress?.call(p.clamp(0.0, 1.0));
    }
  }

  void Function(double progress)? _exportProgress;

  void _ensureEventListening() {
    if (_eventSub != null) return;
    _eventSub = _events.receiveBroadcastStream().listen(_onEvent);
  }

  /// Probe duration / size / audio via AVFoundation or Media3 — not FFprobe.
  Future<({bool hasAudio, Duration? duration, int width, int height})> probe(
    String path,
  ) async {
    final result = await _channel.invokeMapMethod<String, dynamic>('probe', {
      'path': path,
    });
    if (result == null) {
      return (hasAudio: false, duration: null, width: 1080, height: 1920);
    }
    final durationMs = result['durationMs'] as int?;
    return (
      hasAudio: result['hasAudio'] as bool? ?? false,
      duration: durationMs == null ? null : Duration(milliseconds: durationMs),
      width: result['width'] as int? ?? 1080,
      height: result['height'] as int? ?? 1920,
    );
  }

  /// Decode mono PCM peaks on-device (ExtAudioFile / MediaCodec).
  Future<({List<double> peaks, Duration duration})?> decodeWaveform(
    String path, {
    int peakCount = 240,
  }) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'decodeWaveform',
      {'path': path, 'peakCount': peakCount},
    );
    if (result == null) return null;
    final raw = result['peaks'];
    if (raw is! List) return null;
    final peaks = raw.map((e) => (e as num).toDouble()).toList(growable: false);
    final durationMs = result['durationMs'] as int? ?? 0;
    return (peaks: peaks, duration: Duration(milliseconds: durationMs));
  }

  /// Export with the OS encoder (VideoToolbox / MediaCodec via Media3).
  Future<String> export({
    required Map<String, dynamic> request,
    void Function(double progress)? onProgress,
  }) async {
    if (!isPlatformSupported) {
      throw StateError('Native export requires iOS or Android');
    }
    _exportProgress = onProgress;
    _ensureEventListening();
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'export',
        request,
      );
      final path = result?['outputPath'] as String?;
      if (path == null || path.isEmpty) {
        throw StateError('Native export returned no output');
      }
      return path;
    } finally {
      _exportProgress = null;
    }
  }

  Widget buildPreview({BoxFit fit = BoxFit.contain}) {
    final id = _textureId;
    if (!_active || id == null) {
      return const ColoredBox(color: Color(0xFF000000));
    }
    return FittedBox(
      fit: fit,
      child: SizedBox(
        width: 720,
        height: 1280,
        child: Texture(textureId: id),
      ),
    );
  }
}
