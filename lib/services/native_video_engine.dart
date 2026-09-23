import 'dart:async';
import 'dart:io';

import 'package:aveditor/models/applied_transition.dart';
import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/transition_role_effect.dart';
import 'package:aveditor/services/export_service.dart';
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
///          ├── iOS: AVPlayer + AVVideoCompositing (Metal)
///          └── Android: MediaCodec + GLES slide/push
/// ```
///
/// iOS preview and album export share [ExportFrameCompositor].
/// Android preview still only composites slide / push / cover.
class NativeVideoEngine {
  NativeVideoEngine._();

  static final NativeVideoEngine instance = NativeVideoEngine._();

  static const _channel = MethodChannel(
    'com.smart.aveditor/native_video_engine',
  );
  static const _events = EventChannel(
    'com.smart.aveditor/native_video_engine/events',
  );

  static const _opacityOnlyXfades = {
    'fade',
    'dissolve',
    'fadeblack',
    'fadewhite',
  };

  /// Slide / push / cover conveyor effects in the native GPU path.
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
  var _timelineActive = false;
  var _playing = false;
  var _hasFrame = false;
  var _previewWidth = 720;
  var _previewHeight = 1280;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  int? get textureId => _textureId;
  bool get isActive => _active;
  bool get isTimelineActive => _timelineActive && _active;
  bool get isPlaying => _playing;
  bool get hasFrame => _hasFrame;
  Duration get position => _position;
  Duration get duration => _duration;
  Stream<Duration> get positionStream => _positionController.stream;
  Stream<bool> get playingStream => _playingController.stream;

  bool get isPlatformSupported =>
      !kIsWeb && (Platform.isIOS || Platform.isAndroid);

  /// Non-opacity transition (candidate for native engine).
  static bool isSpatialPreview(AppliedTransition? applied) {
    if (applied == null || applied.isNone) return false;
    final name = TransitionEngine.instance
        .effectNameFor(applied)
        ?.toLowerCase();
    if (name == null || name.isEmpty) return false;
    return !_opacityOnlyXfades.contains(name);
  }

  /// Native compositor preview. iOS uses the same compositor as album export.
  static bool supports(AppliedTransition? applied) {
    if (!instance.isPlatformSupported) return false;
    if (applied == null || applied.isNone) return false;
    if (Platform.isIOS) {
      final item = TransitionEngine.instance.plan(applied).definition;
      return item != null && ExportService.exportVisualFor(item) != null;
    }
    if (!isSpatialPreview(applied)) return false;
    final name = TransitionEngine.instance
        .effectNameFor(applied)
        ?.toLowerCase();
    if (name == null || name.isEmpty) return false;
    return supportedEffects.contains(name);
  }

  Future<int?> prepareTimeline({
    required String sourcePath,
    required List<ClipSegment> segments,
  }) async {
    if (!Platform.isIOS) return null;
    final encoded = <Map<String, dynamic>>[];
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final next = i < segments.length - 1 ? segments[i + 1] : null;
      final td = next == null
          ? Duration.zero
          : clampedTransitionDuration(segment, next: next);
      final plan = segment.hasTransition
          ? TransitionEngine.instance.plan(segment.transition)
          : null;
      // Every non-cut transition shares duration-preserving A+B packing
      // (centered td on the cut, handles, no rewind).
      // effectName only selects the compositor blend; layout is identical.
      final effect = plan?.effectName?.toLowerCase();
      final role = plan?.definition?.roleEffect;
      final motion = segment.hasTransition && td > Duration.zero
          ? ExportService.transitionMotionFor(segment.transition)
          : const <Map<String, Object>>[];
      encoded.add({
        'startMs': segment.start.inMilliseconds,
        'endMs': segment.end.inMilliseconds,
        if (segment.hasTransition && td > Duration.zero) ...{
          'transitionEffect': (effect == null || effect.isEmpty) ? 'fade' : effect,
          'transitionDurationMs': td.inMilliseconds,
          if (motion.isNotEmpty) 'transitionLayers': motion,
          if (role != null) ...{
            'transitionKind': role.kind,
            'transitionReverse': role.reverse,
            'transitionParams': {
              for (final entry in role.params.entries)
                if (entry.value is num ||
                    entry.value is bool ||
                    entry.value is String)
                  entry.key: entry.value,
            },
          },
        },
      });
    }
    await dispose();
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'prepareTimeline',
        {'sourcePath': sourcePath, 'segments': encoded},
      );
      final textureId = result?['textureId'] as int?;
      if (textureId == null) return null;
      _textureId = textureId;
      _previewWidth = result?['width'] as int? ?? 720;
      _previewHeight = result?['height'] as int? ?? 1280;
      final durationMs = result?['durationMs'] as int?;
      if (durationMs != null && durationMs > 0) {
        _duration = Duration(milliseconds: durationMs);
      } else {
        // Fallback: source-time composition spans the last segment end.
        var endMs = 0;
        for (final segment in segments) {
          final ms = segment.end.inMilliseconds;
          if (ms > endMs) endMs = ms;
        }
        _duration = Duration(milliseconds: endMs);
      }
      _position = Duration.zero;
      _active = true;
      _timelineActive = true;
      _playing = false;
      _hasFrame = false;
      _ensureEventListening();
      return textureId;
    } on PlatformException catch (e, st) {
      if (kDebugMode) {
        debugPrint('NativeVideoEngine.prepareTimeline failed: $e\n$st');
      }
      await dispose();
      return null;
    }
  }

  Future<int?> prepareTransition({
    required String sourcePath,
    required ClipSegment outgoing,
    required ClipSegment incoming,
    required AppliedTransition transition,
  }) async {
    if (!supports(transition)) return null;

    final td = clampedTransitionDuration(outgoing, next: incoming);
    if (td <= Duration.zero) return null;

    final plan = TransitionEngine.instance.plan(transition);
    final effect = plan.effectName?.toLowerCase();
    if (effect == null || effect.isEmpty) return null;
    final role = plan.definition?.roleEffect;
    final motion = ExportService.transitionMotionFor(transition);

    await dispose();

    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'prepareTransition',
        {
          'sourcePath': sourcePath,
          'outgoingStartMs':
              (outgoing.end -
                      Duration(milliseconds: transitionHalfMs(td).before))
                  .inMilliseconds,
          'outgoingEndMs': outgoing.end.inMilliseconds,
          'incomingStartMs': incoming.start.inMilliseconds,
          'incomingEndMs':
              (incoming.start +
                      Duration(milliseconds: transitionHalfMs(td).after))
                  .inMilliseconds,
          'durationMs': td.inMilliseconds,
          'effect': effect,
          if (motion.isNotEmpty) 'transitionLayers': motion,
          if (role != null) ...{
            'transitionKind': role.kind,
            'transitionReverse': role.reverse,
            'transitionParams': {
              for (final entry in role.params.entries)
                if (entry.value is num ||
                    entry.value is bool ||
                    entry.value is String)
                  entry.key: entry.value,
            },
          },
        },
      );
      debugPrint(
        '[TL] prepareTransition td=${td.inMilliseconds}ms '
        'half=${transitionHalfMs(td).before}+${transitionHalfMs(td).after} '
        'effect=$effect',
      );
      if (result == null) return null;

      final textureId = result['textureId'] as int?;
      final durationMs = result['durationMs'] as int? ?? td.inMilliseconds;
      if (textureId == null) return null;

      _textureId = textureId;
      _duration = Duration(milliseconds: durationMs);
      _previewWidth = result['width'] as int? ?? 720;
      _previewHeight = result['height'] as int? ?? 1280;
      _position = Duration.zero;
      _active = true;
      _timelineActive = false;
      _playing = false;
      _hasFrame = false;
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
    // Optimistic so the transport icon flips before the platform round-trip.
    _playing = true;
    if (!_playingController.isClosed) _playingController.add(true);
    await _channel.invokeMethod<void>('play');
  }

  Future<void> pause() async {
    if (!_active) return;
    _playing = false;
    if (!_playingController.isClosed) _playingController.add(false);
    await _channel.invokeMethod<void>('pause');
  }

  Future<void> seek(Duration position, {bool resume = false}) async {
    if (!_active) return;
    final ms = _clampPositionMs(position.inMilliseconds);
    await _channel.invokeMethod<void>('seek', {'positionMs': ms});
    _position = Duration(milliseconds: ms);
    if (!_positionController.isClosed) _positionController.add(_position);
    if (resume) await play();
  }

  /// Decode and publish one composited frame before showing the Texture.
  Future<bool> preroll(Duration position) async {
    if (!_active) return false;
    final ms = _clampPositionMs(position.inMilliseconds);
    try {
      final ready = await _channel.invokeMethod<bool>('preroll', {
        'positionMs': ms,
      });
      if (ready == true) {
        _hasFrame = true;
        _position = Duration(milliseconds: ms);
        if (!_positionController.isClosed) _positionController.add(_position);
      }
      return _hasFrame;
    } on PlatformException catch (e, st) {
      if (kDebugMode) {
        debugPrint('NativeVideoEngine.preroll failed: $e\n$st');
      }
      return _hasFrame;
    }
  }

  int _clampPositionMs(int ms) {
    if (_duration <= Duration.zero) {
      // Duration not reported yet — never clamp the target down to 0.
      return ms < 0 ? 0 : ms;
    }
    return ms.clamp(0, _duration.inMilliseconds);
  }

  Future<void> dispose() async {
    if (_active || _textureId != null) {
      try {
        await _channel.invokeMethod<void>('dispose');
      } catch (_) {}
    }
    _textureId = null;
    _active = false;
    _timelineActive = false;
    _playing = false;
    _hasFrame = false;
    _previewWidth = 720;
    _previewHeight = 1280;
    _position = Duration.zero;
    _duration = Duration.zero;
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    final map = Map<String, dynamic>.from(event);
    final type = map['type'] as String?;
    if (type == 'position') {
      final ms = map['positionMs'] as int? ?? 0;
      _position = Duration(milliseconds: ms);
      if (!_positionController.isClosed) _positionController.add(_position);
      return;
    }
    if (type == 'playing') {
      _playing = map['playing'] as bool? ?? false;
      if (!_playingController.isClosed) _playingController.add(_playing);
      return;
    }
    if (type == 'completed') {
      _playing = false;
      _position = _duration;
      if (!_playingController.isClosed) _playingController.add(false);
      if (!_positionController.isClosed) _positionController.add(_position);
      return;
    }
    if (type == 'exportProgress') {
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
      debugPrint(
        'NativeVideoEngine.export start segments='
        '${(request['segments'] as List?)?.length ?? 0} '
        'durationMs=${request['durationMs']}',
      );
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'export',
        request,
      );
      final path = result?['outputPath'] as String?;
      if (path == null || path.isEmpty) {
        throw StateError('Native export returned no output');
      }
      debugPrint('NativeVideoEngine.export done path=$path');
      return path;
    } catch (error, stack) {
      debugPrint('NativeVideoEngine.export failed: $error\n$stack');
      rethrow;
    } finally {
      _exportProgress = null;
    }
  }

  Widget buildPreview({BoxFit fit = BoxFit.contain}) {
    final id = _textureId;
    if (!_active || id == null || !_hasFrame) {
      return const ColoredBox(color: Color(0xFF000000));
    }
    return FittedBox(
      fit: fit,
      child: SizedBox(
        width: _previewWidth.toDouble(),
        height: _previewHeight.toDouble(),
        child: Texture(textureId: id),
      ),
    );
  }
}
