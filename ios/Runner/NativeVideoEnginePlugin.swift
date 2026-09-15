import AVFoundation
import CoreImage
import CoreMedia
import Flutter
import Metal
import UIKit

// =============================================================================
// Native Preview Engine (CapCut-style)
//
//   Timeline clock
//        ↓
//   FrameResolver  → sourceTimeA / sourceTimeB / progress / effect
//        ↓
//   StreamingDecoder A (+ B in transitions)   ← continuous AVAssetReader
//        ↓
//   Metal compositor (preferredTransform + transition)
//        ↓
//   Flutter Texture
//
// No AVPlayer for video frames. Seek rebuilds the reader; play only advances.
// =============================================================================

final class NativeVideoEnginePlugin: NSObject, FlutterPlugin {
  static let channelName = "com.smart.aveditor/native_video_engine"
  static let eventName = "com.smart.aveditor/native_video_engine/events"

  private let registrar: FlutterPluginRegistrar
  private var session: PreviewEngineSession?
  private var eventSink: FlutterEventSink?

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = NativeVideoEnginePlugin(registrar: registrar)
    let method = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    method.setMethodCallHandler(instance.handle)
    let events = FlutterEventChannel(
      name: eventName,
      binaryMessenger: registrar.messenger()
    )
    events.setStreamHandler(instance)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "prepareTimeline":
      guard let args = call.arguments as? [String: Any],
            let sourcePath = args["sourcePath"] as? String,
            let segments = args["segments"] as? [[String: Any]],
            let durationMs = args["durationMs"] as? Int
      else {
        result(FlutterError(code: "bad_args", message: "prepareTimeline", details: nil))
        return
      }
      let width = args["width"] as? Int ?? 720
      let height = args["height"] as? Int ?? 1280
      session?.dispose()
      do {
        let s = try PreviewEngineSession(
          registrar: registrar,
          sourcePath: sourcePath,
          segments: segments,
          durationMs: durationMs,
          maxWidth: width,
          maxHeight: height,
          onEvent: { [weak self] e in self?.eventSink?(e) }
        )
        session = s
        result([
          "textureId": s.textureId,
          "durationMs": durationMs,
          "width": s.renderWidth,
          "height": s.renderHeight,
        ])
      } catch {
        result(FlutterError(code: "prepare_failed", message: error.localizedDescription, details: nil))
      }

    case "prepareTransition":
      guard let args = call.arguments as? [String: Any],
            let sourcePath = args["sourcePath"] as? String,
            let effect = args["effect"] as? String,
            let durationMs = args["durationMs"] as? Int,
            let outStartMs = args["outgoingStartMs"] as? Int,
            let outEndMs = args["outgoingEndMs"] as? Int,
            let inStartMs = args["incomingStartMs"] as? Int,
            let inEndMs = args["incomingEndMs"] as? Int
      else {
        result(FlutterError(code: "bad_args", message: "prepareTransition", details: nil))
        return
      }
      session?.dispose()
      do {
        let segments: [[String: Any]] = [
          [
            "startMs": outStartMs,
            "endMs": outEndMs,
            "transitionEffect": effect,
            "transitionDurationMs": durationMs,
          ],
          ["startMs": inStartMs, "endMs": inEndMs],
        ]
        let s = try PreviewEngineSession(
          registrar: registrar,
          sourcePath: sourcePath,
          segments: segments,
          durationMs: durationMs,
          maxWidth: 720,
          maxHeight: 1280,
          onEvent: { [weak self] e in self?.eventSink?(e) }
        )
        session = s
        result([
          "textureId": s.textureId,
          "durationMs": durationMs,
          "width": s.renderWidth,
          "height": s.renderHeight,
        ])
      } catch {
        result(FlutterError(code: "prepare_failed", message: error.localizedDescription, details: nil))
      }

    case "play":
      session?.play()
      result(nil)
    case "pause":
      session?.pause()
      result(nil)
    case "seek":
      let ms = (call.arguments as? [String: Any])?["positionMs"] as? Int ?? 0
      session?.seek(toMs: ms)
      result(nil)
    case "preroll":
      let ms = (call.arguments as? [String: Any])?["positionMs"] as? Int ?? 0
      session?.preroll(toMs: ms) { ready in result(ready) }
    case "dispose":
      session?.dispose()
      session = nil
      result(nil)

    case "probe":
      guard let path = (call.arguments as? [String: Any])?["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "probe", details: nil))
        return
      }
      do { result(try NativeVideoEngineMedia.probe(path: path)) }
      catch {
        result(FlutterError(code: "probe_failed", message: error.localizedDescription, details: nil))
      }

    case "decodeWaveform":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "decodeWaveform", details: nil))
        return
      }
      let peakCount = args["peakCount"] as? Int ?? 240
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let payload = try NativeVideoEngineMedia.decodeWaveform(path: path, peakCount: peakCount)
          DispatchQueue.main.async { result(payload) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "waveform_failed", message: error.localizedDescription, details: nil))
          }
        }
      }

    case "export":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "bad_args", message: "export", details: nil))
        return
      }
      NativeVideoEngineMedia.export(
        args: args,
        onProgress: { [weak self] p in
          self?.eventSink?(["type": "exportProgress", "progress": p])
        },
        completion: { exportResult in
          DispatchQueue.main.async {
            switch exportResult {
            case .success(let path): result(["outputPath": path])
            case .failure(let error):
              result(FlutterError(code: "export_failed", message: error.localizedDescription, details: nil))
            }
          }
        }
      )

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

extension NativeVideoEnginePlugin: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}

// MARK: - Frame Resolver

struct PreviewSegment {
  let sourceStartMs: Int
  let sourceEndMs: Int
  let compositionStartMs: Int
  let compositionEndMs: Int
  let transitionStartMs: Int?
  let transitionEndMs: Int?
  let effect: String?
  let incomingSourceStartMs: Int?
  let volume: Float
}

struct ResolvedFrames {
  let primaryMs: Int
  let secondaryMs: Int?
  let progress: Float
  let effect: String?
}

enum PreviewFrameResolver {
  /// Composition clock = sum of segment durations (matches editor timeline strip).
  /// Transitions blend in the outgoing tail without shrinking time.
  static func pack(_ raw: [[String: Any]]) -> [PreviewSegment] {
    var out: [PreviewSegment] = []
    var cursor = 0
    for (i, seg) in raw.enumerated() {
      let start = seg["startMs"] as? Int ?? 0
      let end = seg["endMs"] as? Int ?? 0
      let dur = max(0, end - start)
      let td = max(0, seg["transitionDurationMs"] as? Int ?? 0)
      let effect = (seg["transitionEffect"] as? String)?.lowercased()
      let volume: Float = {
        if let n = seg["volume"] as? NSNumber { return n.floatValue }
        if let d = seg["volume"] as? Double { return Float(d) }
        return 1
      }()
      let nextStart = i + 1 < raw.count ? (raw[i + 1]["startMs"] as? Int ?? 0) : nil
      let c0 = cursor
      let c1 = cursor + dur
      if td > 0, let nextStart {
        out.append(PreviewSegment(
          sourceStartMs: start, sourceEndMs: end,
          compositionStartMs: c0, compositionEndMs: c1,
          transitionStartMs: c1 - td, transitionEndMs: c1,
          effect: effect ?? "dissolve",
          incomingSourceStartMs: nextStart,
          volume: max(0, min(volume, 2))
        ))
      } else {
        out.append(PreviewSegment(
          sourceStartMs: start, sourceEndMs: end,
          compositionStartMs: c0, compositionEndMs: c1,
          transitionStartMs: nil, transitionEndMs: nil,
          effect: nil, incomingSourceStartMs: nil,
          volume: max(0, min(volume, 2))
        ))
      }
      cursor = c1
    }
    return out
  }

  static func resolve(compositionMs: Int, segments: [PreviewSegment]) -> ResolvedFrames? {
    guard !segments.isEmpty else { return nil }
    let active = segments.first {
      compositionMs >= $0.compositionStartMs && compositionMs < $0.compositionEndMs
    } ?? segments.last!
    let local = compositionMs - active.compositionStartMs
    let primary = min(active.sourceStartMs + local, max(active.sourceStartMs, active.sourceEndMs - 1))

    if let t0 = active.transitionStartMs,
       let t1 = active.transitionEndMs,
       let inStart = active.incomingSourceStartMs,
       compositionMs >= t0, compositionMs < t1 {
      let td = max(1, t1 - t0)
      let p = Float(compositionMs - t0) / Float(td)
      return ResolvedFrames(
        primaryMs: primary,
        secondaryMs: inStart + (compositionMs - t0),
        progress: min(max(p, 0), 1),
        effect: active.effect
      )
    }
    return ResolvedFrames(primaryMs: primary, secondaryMs: nil, progress: 0, effect: nil)
  }
}

// MARK: - Streaming decoder (continuous)

/// One long-lived AVAssetReader. Play advances sample-by-sample.
/// Only scrub / large reverse jumps reopen the reader.
final class StreamingVideoDecoder {
  private let asset: AVURLAsset
  private let track: AVAssetTrack
  private let lock = NSLock()
  private var reader: AVAssetReader?
  private var output: AVAssetReaderTrackOutput?
  private var current: (ms: Int, buffer: CVPixelBuffer)?
  private var streamOriginMs = 0
  private var alive = true

  var preferredTransform: CGAffineTransform { track.preferredTransform }

  var orientedSize: CGSize {
    let n = track.naturalSize.applying(preferredTransform)
    return CGSize(width: abs(n.width), height: abs(n.height))
  }

  init(path: String) throws {
    asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = asset.tracks(withMediaType: .video).first else {
      throw NSError(domain: "PreviewEngine", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "No video track",
      ])
    }
    self.track = track
  }

  func seek(toMs ms: Int) {
    lock.lock()
    defer { lock.unlock() }
    reopen(fromMs: max(0, ms))
    _ = pump(untilMs: ms)
  }

  /// Forward-only pull. Returns the frame at or just after [ms].
  func frame(atMs ms: Int) -> CVPixelBuffer? {
    lock.lock()
    defer { lock.unlock() }
    guard alive else { return current?.buffer }

    // Reverse, stream death, or cut-boundary jump (kept-range gap) → reopen.
    let needReseek =
      reader == nil ||
      reader?.status != .reading ||
      (current.map { ms + 120 < $0.ms } ?? false) ||
      (current.map { ms > $0.ms + 450 } ?? false) ||
      ms < streamOriginMs - 30

    if needReseek {
      reopen(fromMs: max(0, ms - 1))
    }
    return pump(untilMs: ms)?.buffer ?? current?.buffer
  }

  func dispose() {
    lock.lock()
    alive = false
    reader?.cancelReading()
    reader = nil
    output = nil
    current = nil
    lock.unlock()
  }

  private func reopen(fromMs ms: Int) {
    reader?.cancelReading()
    reader = nil
    output = nil
    current = nil
    streamOriginMs = max(0, ms)

    guard let r = try? AVAssetReader(asset: asset) else { return }
    // Copy so CI/Metal can read after the next pump invalidates the sample.
    let settings: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]
    let o = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    o.alwaysCopiesSampleData = true
    guard r.canAdd(o) else { return }
    r.add(o)

    let start = CMTime(value: CMTimeValue(streamOriginMs), timescale: 1000)
    var dur = CMTimeSubtract(track.timeRange.end, start)
    if CMTimeCompare(dur, .zero) <= 0 {
      dur = CMTime(seconds: 0.05, preferredTimescale: 600)
    }
    r.timeRange = CMTimeRange(start: start, duration: dur)
    guard r.startReading() else { return }
    reader = r
    output = o
  }

  @discardableResult
  private func pump(untilMs targetMs: Int) -> (ms: Int, buffer: CVPixelBuffer)? {
    guard let output, let reader, reader.status == .reading else { return current }
    if let current, current.ms >= targetMs { return current }

    var guardCount = 0
    while reader.status == .reading, guardCount < 120 {
      guardCount += 1
      guard let sample = output.copyNextSampleBuffer(),
            let buf = CMSampleBufferGetImageBuffer(sample)
      else { break }
      let pts = Int((CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) * 1000).rounded())
      current = (pts, buf)
      if pts >= targetMs { return current }
    }
    return current
  }
}

// MARK: - Continuous composition audio (no VideoPlayer / no seek-per-tick)

/// Maps composition clock → source PCM and feeds AVAudioPlayerNode ahead of the
/// playhead. Seek / cut boundaries reopen the reader; play only advances.
final class PreviewAudioPlayer {
  private let asset: AVURLAsset
  private let segments: [PreviewSegment]
  private let durationMs: Int
  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private var track: AVAssetTrack?
  private var reader: AVAssetReader?
  private var output: AVAssetReaderTrackOutput?
  private var format: AVAudioFormat?
  private var playing = false
  private var alive = true
  private var scheduleCursorMs = 0
  private var lastSourceMs = -1
  private var lastSegStart = -1
  private var pendingBuffers = 0
  private var feedGeneration = 0
  private let queue = DispatchQueue(label: "preview.audio.feed", qos: .userInitiated)
  private let lock = NSLock()

  init?(path: String, segments: [PreviewSegment], durationMs: Int) {
    asset = AVURLAsset(url: URL(fileURLWithPath: path))
    self.segments = segments
    self.durationMs = max(1, durationMs)
    guard let t = asset.tracks(withMediaType: .audio).first else { return nil }
    track = t
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: nil)
    engine.mainMixerNode.outputVolume = 1
  }

  func seek(toCompositionMs ms: Int) {
    lock.lock()
    feedGeneration += 1
    playing = false
    scheduleCursorMs = min(max(0, ms), durationMs)
    lastSourceMs = -1
    lastSegStart = -1
    pendingBuffers = 0
    hardResetNodeLocked()
    reopenReader(sourceMs: sourceMs(forComposition: scheduleCursorMs) ?? 0)
    lock.unlock()
  }

  func play() {
    lock.lock()
    feedGeneration += 1
    let gen = feedGeneration
    playing = true
    scheduleCursorMs = min(max(0, scheduleCursorMs), durationMs)
    lastSourceMs = -1
    lastSegStart = -1
    pendingBuffers = 0
    hardResetNodeLocked()
    reopenReader(sourceMs: sourceMs(forComposition: scheduleCursorMs) ?? 0)
    lock.unlock()

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setActive(true)
      if !engine.isRunning { try engine.start() }
      node.play()
    } catch {
      lock.lock()
      playing = false
      lock.unlock()
      return
    }
    queue.async { [weak self] in self?.feedLoop(generation: gen) }
  }

  func pause() {
    lock.lock()
    feedGeneration += 1
    playing = false
    pendingBuffers = 0
    hardResetNodeLocked()
    reader?.cancelReading()
    reader = nil
    output = nil
    lock.unlock()
  }

  func dispose() {
    lock.lock()
    alive = false
    playing = false
    feedGeneration += 1
    pendingBuffers = 0
    hardResetNodeLocked()
    reader?.cancelReading()
    reader = nil
    output = nil
    if engine.isRunning { engine.stop() }
    lock.unlock()
  }

  private func hardResetNodeLocked() {
    node.stop()
    // Drop any scheduled PCM so pause→play cannot stall on old completions.
    if engine.isRunning {
      node.reset()
    }
  }

  private func feedLoop(generation: Int) {
    while true {
      lock.lock()
      let run = alive && playing && generation == feedGeneration
      let cursor = scheduleCursorMs
      let pending = pendingBuffers
      lock.unlock()
      guard run else { return }
      if cursor >= durationMs {
        lock.lock()
        if generation == feedGeneration {
          playing = false
          hardResetNodeLocked()
        }
        lock.unlock()
        return
      }
      if pending >= 6 {
        Thread.sleep(forTimeInterval: 0.01)
        continue
      }

      lock.lock()
      guard generation == feedGeneration, playing else {
        lock.unlock()
        return
      }
      guard let buf = nextBuffer() else {
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.008)
        continue
      }
      pendingBuffers += 1
      let gen = generation
      lock.unlock()
      node.scheduleBuffer(buf) { [weak self] in
        guard let self else { return }
        self.lock.lock()
        if gen == self.feedGeneration {
          self.pendingBuffers = max(0, self.pendingBuffers - 1)
        }
        self.lock.unlock()
      }
    }
  }

  private func nextBuffer() -> AVAudioPCMBuffer? {
    guard let source = sourceMs(forComposition: scheduleCursorMs) else { return nil }
    let seg = activeSegment(forComposition: scheduleCursorMs)
    let vol = seg?.volume ?? 1

    if lastSegStart != (seg?.compositionStartMs ?? -1)
        || lastSourceMs < 0
        || source + 80 < lastSourceMs
        || source > lastSourceMs + 400 {
      reopenReader(sourceMs: source)
      lastSegStart = seg?.compositionStartMs ?? -1
    }

    guard let sample = readSample() else { return nil }
    guard let pcm = makePCMBuffer(from: sample) else { return nil }
    applyVolume(pcm, volume: vol)

    let ms = Int(Double(pcm.frameLength) / pcm.format.sampleRate * 1000.0)
    scheduleCursorMs = min(scheduleCursorMs + max(ms, 1), durationMs)
    lastSourceMs = source + ms
    return pcm
  }

  private func activeSegment(forComposition ms: Int) -> PreviewSegment? {
    segments.first { ms >= $0.compositionStartMs && ms < $0.compositionEndMs } ?? segments.last
  }

  private func sourceMs(forComposition ms: Int) -> Int? {
    guard let seg = activeSegment(forComposition: ms) else { return nil }
    let local = ms - seg.compositionStartMs
    return min(seg.sourceStartMs + local, max(seg.sourceStartMs, seg.sourceEndMs - 1))
  }

  private func reopenReader(sourceMs: Int) {
    reader?.cancelReading()
    reader = nil
    output = nil
    guard let track else { return }
    guard let r = try? AVAssetReader(asset: asset) else { return }
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    let o = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    o.alwaysCopiesSampleData = false
    guard r.canAdd(o) else { return }
    r.add(o)
    let start = CMTime(value: CMTimeValue(max(0, sourceMs)), timescale: 1000)
    var dur = CMTimeSubtract(track.timeRange.end, start)
    if CMTimeCompare(dur, .zero) <= 0 {
      dur = CMTime(seconds: 0.05, preferredTimescale: 600)
    }
    r.timeRange = CMTimeRange(start: start, duration: dur)
    guard r.startReading() else { return }
    reader = r
    output = o
    lastSourceMs = sourceMs
  }

  private func readSample() -> CMSampleBuffer? {
    guard let output, let reader, reader.status == .reading else { return nil }
    return output.copyNextSampleBuffer()
  }

  private func makePCMBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
    guard let formatDesc = CMSampleBufferGetFormatDescription(sample) else { return nil }
    guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
      return nil
    }
    let asbd = asbdPtr.pointee
    let channels = max(1, Int(asbd.mChannelsPerFrame))
    let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 44100
    guard let fmt = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: AVAudioChannelCount(channels),
      interleaved: false
    ) else { return nil }
    format = fmt

    var sizeNeeded = 0
    var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sample,
      bufferListSizeNeededOut: &sizeNeeded,
      bufferListOut: nil,
      bufferListSize: 0,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
      blockBufferOut: nil
    )
    // First call may return paramErr while filling sizeNeeded.
    guard sizeNeeded > 0 || status == noErr else { return nil }
    if sizeNeeded <= 0 {
      sizeNeeded = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size * max(0, channels - 1)
    }

    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: sizeNeeded,
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }
    let ablPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    var blockBuffer: CMBlockBuffer?
    status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sample,
      bufferListSizeNeededOut: nil,
      bufferListOut: ablPtr,
      bufferListSize: sizeNeeded,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
      blockBufferOut: &blockBuffer
    )
    guard status == noErr else { return nil }
    defer { blockBuffer = nil }

    let numSamples = CMSampleBufferGetNumSamples(sample)
    guard numSamples > 0 else { return nil }
    guard let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(numSamples)) else {
      return nil
    }
    pcm.frameLength = AVAudioFrameCount(numSamples)

    let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
    guard let src = abl.first?.mData else { return nil }
    let src16 = src.assumingMemoryBound(to: Int16.self)
    for ch in 0..<channels {
      guard let dst = pcm.floatChannelData?[ch] else { continue }
      for i in 0..<numSamples {
        let s = src16[i * channels + ch]
        dst[i] = Float(s) / Float(Int16.max)
      }
    }
    return pcm
  }

  private func applyVolume(_ buffer: AVAudioPCMBuffer, volume: Float) {
    guard abs(volume - 1) > 0.001, let channels = buffer.floatChannelData else { return }
    let n = Int(buffer.frameLength)
    let chs = Int(buffer.format.channelCount)
    for c in 0..<chs {
      let ptr = channels[c]
      for i in 0..<n { ptr[i] *= volume }
    }
  }
}

// MARK: - Preview session

final class PreviewEngineSession: NSObject {
  let textureId: Int64
  let renderWidth: Int
  let renderHeight: Int

  private let registrar: FlutterPluginRegistrar
  private let texture: PreviewTexture
  private let segments: [PreviewSegment]
  private let durationMs: Int
  private let transform: CGAffineTransform
  private let decoderA: StreamingVideoDecoder
  private let decoderB: StreamingVideoDecoder
  private let audio: PreviewAudioPlayer?
  private let gpu = PreviewMetalCompositor()
  private let onEvent: ([String: Any]) -> Void

  private var link: CADisplayLink?
  private var playing = false
  private var positionMs = 0
  private var wallAnchor: CFTimeInterval = 0
  private var posAnchor = 0
  private var completed = false

  private let work = DispatchQueue(label: "preview.engine.render", qos: .userInteractive)
  private var busy = false
  private var latestRequest: Int?

  init(
    registrar: FlutterPluginRegistrar,
    sourcePath: String,
    segments: [[String: Any]],
    durationMs: Int,
    maxWidth: Int,
    maxHeight: Int,
    onEvent: @escaping ([String: Any]) -> Void
  ) throws {
    self.registrar = registrar
    self.segments = PreviewFrameResolver.pack(segments)
    self.durationMs = max(1, durationMs)
    self.onEvent = onEvent
    decoderA = try StreamingVideoDecoder(path: sourcePath)
    decoderB = try StreamingVideoDecoder(path: sourcePath)
    audio = PreviewAudioPlayer(
      path: sourcePath,
      segments: self.segments,
      durationMs: max(1, durationMs)
    )
    transform = decoderA.preferredTransform

    let oriented = decoderA.orientedSize
    let sx = CGFloat(max(maxWidth, 1)) / max(oriented.width, 1)
    let sy = CGFloat(max(maxHeight, 1)) / max(oriented.height, 1)
    let s = min(sx, sy)
    renderWidth = max(2, Int((oriented.width * s).rounded() / 2) * 2)
    renderHeight = max(2, Int((oriented.height * s).rounded() / 2) * 2)

    texture = PreviewTexture()
    textureId = registrar.textures().register(texture)
    super.init()

    decoderA.seek(toMs: 0)
    let dl = CADisplayLink(target: self, selector: #selector(tick))
    if #available(iOS 15.0, *) {
      dl.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
    } else {
      dl.preferredFramesPerSecond = 30
    }
    dl.add(to: .main, forMode: .common)
    link = dl
  }

  func play() {
    completed = false
    playing = true
    busy = false
    latestRequest = nil
    wallAnchor = CACurrentMediaTime()
    posAnchor = positionMs
    if let r = PreviewFrameResolver.resolve(compositionMs: positionMs, segments: segments) {
      decoderA.seek(toMs: r.primaryMs)
      if let s = r.secondaryMs { decoderB.seek(toMs: s) }
    }
    audio?.seek(toCompositionMs: positionMs)
    audio?.play()
    onEvent(["type": "playing", "playing": true])
  }

  func pause() {
    playing = false
    audio?.pause()
    busy = false
    latestRequest = nil
    onEvent(["type": "playing", "playing": false])
  }

  func seek(toMs ms: Int) {
    positionMs = min(max(0, ms), durationMs)
    wallAnchor = CACurrentMediaTime()
    posAnchor = positionMs
    if let r = PreviewFrameResolver.resolve(compositionMs: positionMs, segments: segments) {
      decoderA.seek(toMs: r.primaryMs)
      if let s = r.secondaryMs { decoderB.seek(toMs: s) }
    }
    if playing { audio?.seek(toCompositionMs: positionMs) }
    requestRender(positionMs)
    onEvent(["type": "position", "positionMs": positionMs])
  }

  func preroll(toMs ms: Int, completion: @escaping (Bool) -> Void) {
    positionMs = min(max(0, ms), durationMs)
    wallAnchor = CACurrentMediaTime()
    posAnchor = positionMs
    latestRequest = nil
    if let r = PreviewFrameResolver.resolve(compositionMs: positionMs, segments: segments) {
      decoderA.seek(toMs: r.primaryMs)
      if let s = r.secondaryMs { decoderB.seek(toMs: s) }
    }
    let target = positionMs
    work.async { [weak self] in
      guard let self else {
        DispatchQueue.main.async { completion(false) }
        return
      }
      let ok = self.draw(at: target)
      DispatchQueue.main.async {
        self.onEvent(["type": "position", "positionMs": self.positionMs])
        completion(ok)
      }
    }
  }

  func dispose() {
    link?.invalidate()
    link = nil
    playing = false
    audio?.dispose()
    decoderA.dispose()
    decoderB.dispose()
    registrar.textures().unregisterTexture(textureId)
  }

  @objc private func tick() {
    if playing {
      let elapsed = CACurrentMediaTime() - wallAnchor
      positionMs = min(posAnchor + Int(elapsed * 1000), durationMs)
      if positionMs >= durationMs {
        playing = false
        positionMs = durationMs
        audio?.pause()
        if !completed {
          completed = true
          onEvent(["type": "completed"])
          onEvent(["type": "playing", "playing": false])
        }
      }
      onEvent(["type": "position", "positionMs": positionMs])
      requestRender(positionMs)
    }
    // When paused, scrub/preroll owns frames — don't fight the decoder every tick.
  }

  private func requestRender(_ ms: Int) {
    latestRequest = ms
    guard !busy else { return }
    busy = true
    work.async { [weak self] in
      guard let self else { return }
      while let target = self.latestRequest {
        self.latestRequest = nil
        _ = self.draw(at: target)
      }
      self.busy = false
      if let again = self.latestRequest {
        self.requestRender(again)
      }
    }
  }

  @discardableResult
  private func draw(at ms: Int) -> Bool {
    guard let resolved = PreviewFrameResolver.resolve(compositionMs: ms, segments: segments) else {
      return false
    }
    guard let frameA = decoderA.frame(atMs: resolved.primaryMs) else {
      return texture.pixelBuffer != nil
    }

    let out: CVPixelBuffer?
    if let sec = resolved.secondaryMs, let effect = resolved.effect,
       let frameB = decoderB.frame(atMs: sec) {
      out = gpu.compose(
        a: frameA, b: frameB,
        progress: CGFloat(resolved.progress),
        effect: effect,
        width: renderWidth, height: renderHeight,
        transform: transform
      )
    } else {
      out = gpu.blit(
        frameA,
        width: renderWidth, height: renderHeight,
        transform: transform
      )
    }
    guard let out else { return texture.pixelBuffer != nil }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.texture.pixelBuffer = out
      self.registrar.textures().textureFrameAvailable(self.textureId)
    }
    return true
  }
}

extension PreviewEngineSession: NativePlaybackSession {}

protocol NativePlaybackSession: AnyObject {
  var textureId: Int64 { get }
  func play()
  func pause()
  func seek(toMs ms: Int)
  func preroll(toMs ms: Int, completion: @escaping (Bool) -> Void)
  func dispose()
}

final class PreviewTexture: NSObject, FlutterTexture {
  var pixelBuffer: CVPixelBuffer?
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    guard let pixelBuffer else { return nil }
    return Unmanaged.passRetained(pixelBuffer)
  }
}

// MARK: - Metal / CoreImage compositor

final class PreviewMetalCompositor {
  private let ci: CIContext

  init() {
    let device = MTLCreateSystemDefaultDevice()!
    ci = CIContext(mtlDevice: device, options: [
      .cacheIntermediates: false,
      .useSoftwareRenderer: false,
    ])
  }

  func blit(
    _ src: CVPixelBuffer,
    width: Int,
    height: Int,
    transform: CGAffineTransform
  ) -> CVPixelBuffer? {
    guard let dst = make(width: width, height: height) else { return nil }
    let image = fit(orient(src, transform: transform), width: width, height: height)
    ci.render(image, to: dst)
    return dst
  }

  func compose(
    a: CVPixelBuffer,
    b: CVPixelBuffer,
    progress t: CGFloat,
    effect: String,
    width: Int,
    height: Int,
    transform: CGAffineTransform
  ) -> CVPixelBuffer? {
    guard let dst = make(width: width, height: height) else { return nil }
    let w = CGFloat(width)
    let h = CGFloat(height)
    var outImg = fit(orient(a, transform: transform), width: width, height: height)
    var inImg = fit(orient(b, transform: transform), width: width, height: height)

    let slide: Set<String> = [
      "slideleft", "slideright", "slideup", "slidedown",
      "coverleft", "coverright", "coverup", "coverdown",
      "pushleft", "pushright", "pushup", "pushdown",
    ]
    let name = effect.lowercased()
    let composed: CIImage
    if slide.contains(name) {
      let (o, i) = offsets(name, t: t, w: w, h: h)
      outImg = outImg.transformed(by: CGAffineTransform(translationX: o.x, y: o.y))
      inImg = inImg.transformed(by: CGAffineTransform(translationX: i.x, y: i.y))
      let canvas = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
      composed = inImg.composited(over: outImg.composited(over: canvas))
    } else {
      let outF = outImg.applyingFilter("CIColorMatrix", parameters: [
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1 - t),
      ])
      let inF = inImg.applyingFilter("CIColorMatrix", parameters: [
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: t),
      ])
      let canvas = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
      composed = inF.composited(over: outF.composited(over: canvas))
    }
    ci.render(composed, to: dst)
    return dst
  }

  private func orient(_ buf: CVPixelBuffer, transform: CGAffineTransform) -> CIImage {
    var image = CIImage(cvPixelBuffer: buf).transformed(by: transform)
    let e = image.extent
    return image.transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
  }

  private func fit(_ image: CIImage, width: Int, height: Int) -> CIImage {
    let target = CGRect(x: 0, y: 0, width: width, height: height)
    var img = image
    var e = img.extent
    let scale = max(target.width / max(e.width, 1), target.height / max(e.height, 1))
    img = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    e = img.extent
    let tx = (target.width - e.width) / 2 - e.origin.x
    let ty = (target.height - e.height) / 2 - e.origin.y
    return img.transformed(by: CGAffineTransform(translationX: tx, y: ty)).cropped(to: target)
  }

  private func make(width: Int, height: Int) -> CVPixelBuffer? {
    var buf: CVPixelBuffer?
    let attrs: [CFString: Any] = [
      kCVPixelBufferMetalCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    CVPixelBufferCreate(
      kCFAllocatorDefault, width, height,
      kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buf
    )
    return buf
  }

  private func offsets(_ effect: String, t: CGFloat, w: CGFloat, h: CGFloat) -> (CGPoint, CGPoint) {
    switch effect {
    case "slideleft", "pushleft", "coverleft":
      return (CGPoint(x: -w * t, y: 0), CGPoint(x: w * (1 - t), y: 0))
    case "slideright", "pushright", "coverright":
      return (CGPoint(x: w * t, y: 0), CGPoint(x: -w * (1 - t), y: 0))
    case "slideup", "pushup", "coverup":
      return (CGPoint(x: 0, y: h * t), CGPoint(x: 0, y: -h * (1 - t)))
    case "slidedown", "pushdown", "coverdown":
      return (CGPoint(x: 0, y: -h * t), CGPoint(x: 0, y: h * (1 - t)))
    default:
      return (CGPoint(x: -w * t, y: 0), CGPoint(x: w * (1 - t), y: 0))
    }
  }
}
