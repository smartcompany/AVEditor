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
/// CapCut-style preview: [prepareTimeline] owns continuous composition
/// video + source audio. VideoPlayer is muted fallback for non-native paths.
/// [prepareTransition] remains for legacy single-cut guest sessions.
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

  /// Slide / push conveyor effects with dedicated GPU offsets.
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

  /// Effects rendered as opacity crossfade in the native timeline compositor.
  static const crossfadeEffects = {
    'fade',
    'dissolve',
    'fadeblack',
    'fadewhite',
    'crossblur',
    'ripple',
    'spinin',
    'spinout',
    'circleopen',
    'circleclose',
    'doorway',
    'swap',
    'cube',
    'mosaic',
    'wipeleft',
    'wiperight',
    'wipeup',
    'wipedown',
    'puzzleleft',
    'puzzleright',
    'crosszoom',
  };

  int? _textureId;
  StreamSubscription<dynamic>? _eventSub;
  final _positionController = StreamController<Duration>.broadcast();
  final _playingController = StreamController<bool>.broadcast();
  var _active = false;
  var _playing = false;
  var _hasFrame = false;
  var _timelineMode = false;
  int _previewWidth = 720;
  int _previewHeight = 1280;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  int? get textureId => _textureId;
  bool get isActive => _active;
  bool get isPlaying => _playing;
  bool get hasFrame => _hasFrame;
  bool get isTimelineMode => _timelineMode && _active;
  int get previewWidth => _previewWidth;
  int get previewHeight => _previewHeight;
  Duration get position => _position;
  Duration get duration => _duration;
  Stream<Duration> get positionStream => _positionController.stream;
  Stream<bool> get playingStream => _playingController.stream;

  bool get isPlatformSupported =>
      !kIsWeb && (Platform.isIOS || Platform.isAndroid);

  /// Whether continuous native timeline preview is available on this device.
  static bool get supportsTimeline => instance.isPlatformSupported;

  /// Non-opacity transition (legacy spatial guest classification).
  static bool isSpatialPreview(AppliedTransition? applied) {
    if (applied == null || applied.isNone) return false;
    final name =
        TransitionEngine.instance.ffmpegNameFor(applied)?.toLowerCase();
    if (name == null || name.isEmpty) return false;
    return !_opacityOnlyXfades.contains(name);
  }

  /// Legacy single-cut GPU guest for slide/push/cover.
  static bool supports(AppliedTransition? applied) {
    if (!instance.isPlatformSupported) return false;
    if (!isSpatialPreview(applied)) return false;
    final name =
        TransitionEngine.instance.ffmpegNameFor(applied)?.toLowerCase();
    if (name == null || name.isEmpty) return false;
    return supportedEffects.contains(name);
  }

  /// Segment maps shared with native export / [prepareTimeline].
  static List<Map<String, dynamic>> buildTimelineSegments(
    List<ClipSegment> segments,
  ) {
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final next = i < segments.length - 1 ? segments[i + 1] : null;
      final td = next == null
          ? Duration.zero
          : clampedTransitionDuration(segment, next: next);
      final effect = segment.hasTransition && td > Duration.zero
          ? TransitionEngine.instance.ffmpegNameFor(segment.transition)
                ?.toLowerCase()
          : null;
      out.add({
        'startMs': segment.start.inMilliseconds,
        'endMs': segment.end.inMilliseconds,
        'volume': segment.volume,
        if (effect != null) ...{
          'transitionEffect': effect,
          'transitionDurationMs': td.inMilliseconds,
        },
      });
    }
    return out;
  }

  /// CapCut-style continuous composition for the full packed timeline.
  ///
  /// Preview clock matches the editor strip (sum of segment durations).
  /// Transition blends happen in the outgoing tail without shrinking time.
  Future<int?> prepareTimeline({
    required String sourcePath,
    required List<ClipSegment> segments,
    double rotationRadians = 0,
    int width = 720,
    int height = 1280,
  }) async {
    if (!supportsTimeline) return null;
    if (segments.isEmpty) return null;

    final previewDuration = totalKeptDuration(segments);
    if (previewDuration <= Duration.zero) return null;

    await dispose();

    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'prepareTimeline',
        {
          'sourcePath': sourcePath,
          'segments': buildTimelineSegments(segments),
          'width': width,
          'height': height,
          'durationMs': previewDuration.inMilliseconds,
          'rotationDegrees': rotationRadians,
        },
      );
      if (result == null) return null;

      final textureId = result['textureId'] as int?;
      final durationMs =
          result['durationMs'] as int? ?? previewDuration.inMilliseconds;
      if (textureId == null) return null;

      _textureId = textureId;
      _duration = Duration(milliseconds: durationMs);
      _previewWidth = result['width'] as int? ?? width;
      _previewHeight = result['height'] as int? ?? height;
      _position = Duration.zero;
      _active = true;
      _playing = false;
      _hasFrame = false;
      _timelineMode = true;
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
      _hasFrame = false;
      _timelineMode = false;
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

  /// Decode and publish one composited frame before showing the Texture.
  Future<bool> preroll(Duration position) async {
    if (!_active) return false;
    final ms = position.inMilliseconds.clamp(0, _duration.inMilliseconds);
    try {
      final ready = await _channel.invokeMethod<bool>('preroll', {
        'positionMs': ms,
      });
      // Keep the last good frame if a scrub decode misses — never blank the preview.
      if (ready == true) {
        _hasFrame = true;
        _position = Duration(milliseconds: ms);
        if (!_positionController.isClosed) _positionController.add(_position);
      } else {
        _position = Duration(milliseconds: ms);
        if (!_positionController.isClosed) _positionController.add(_position);
      }
      return _hasFrame;
    } on PlatformException catch (e, st) {
      if (kDebugMode) {
        debugPrint('NativeVideoEngine.preroll failed: $e\n$st');
      }
      _position = Duration(milliseconds: ms);
      return _hasFrame;
    }
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
    _hasFrame = false;
    _timelineMode = false;
    _previewWidth = 720;
    _previewHeight = 1280;
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
