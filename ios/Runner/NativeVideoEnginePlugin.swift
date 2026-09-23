import AVFoundation
import CoreImage
import CoreMedia
import Flutter
import Metal
import UIKit

/// Native Bridge entry — iOS Native Video Engine (AVFoundation + Metal).
final class NativeVideoEnginePlugin: NSObject, FlutterPlugin {
  static let channelName = "com.smart.aveditor/native_video_engine"
  static let eventName = "com.smart.aveditor/native_video_engine/events"

  private let registrar: FlutterPluginRegistrar
  private var session: NativeVideoEngineSession?
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
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "bad_args", message: "prepareTimeline", details: nil))
        return
      }
      session?.dispose()
      do {
        let built = try makeTimelinePreviewItem(args: args)
        let session = NativeVideoEngineSession(
          registrar: registrar,
          item: built.item,
          renderSize: CGSize(width: built.width, height: built.height),
          onEvent: { [weak self] event in self?.eventSink?(event) }
        )
        self.session = session
        let durationMs = Int((CMTimeGetSeconds(built.item.duration) * 1000).rounded())
        result([
          "textureId": session.textureId,
          "width": session.renderWidth,
          "height": session.renderHeight,
          "durationMs": max(0, durationMs),
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
      let params = args["transitionParams"] as? [String: Any]
      do {
        let session = try NativeVideoEngineSession(
          registrar: registrar,
          sourcePath: sourcePath,
          outgoingStart: CMTime(value: CMTimeValue(outStartMs), timescale: 1000),
          outgoingEnd: CMTime(value: CMTimeValue(outEndMs), timescale: 1000),
          incomingStart: CMTime(value: CMTimeValue(inStartMs), timescale: 1000),
          incomingEnd: CMTime(value: CMTimeValue(inEndMs), timescale: 1000),
          duration: CMTime(value: CMTimeValue(durationMs), timescale: 1000),
          effect: effect.lowercased(),
          kind: (args["transitionKind"] as? String)?.lowercased() ?? "",
          reverse: args["transitionReverse"] as? Bool ?? false,
          layers: exportMotionLayers(args["transitionLayers"]),
          incomingScaleFrom: exportOptionalNumber(params?["incomingScaleFrom"]) ?? 0.84,
          incomingScaleTo: exportOptionalNumber(params?["incomingScaleTo"]) ?? 1,
          wipeEdge: (params?["edge"] as? String)?.lowercased() ?? "",
          onEvent: { [weak self] event in self?.eventSink?(event) }
        )
        self.session = session
        result([
          "textureId": session.textureId,
          "durationMs": durationMs,
          "width": session.renderWidth,
          "height": session.renderHeight,
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
      guard let session else {
        result(nil)
        return
      }
      session.seek(toMs: ms) { _ in result(nil) }
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
      do {
        result(try NativeVideoEngineMedia.probe(path: path))
      } catch {
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
        onProgress: { [weak self] progress in
          self?.eventSink?([
            "type": "exportProgress",
            "progress": progress,
          ])
        },
        completion: { exportResult in
          DispatchQueue.main.async {
            switch exportResult {
            case .success(let path):
              result(["outputPath": path])
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

// MARK: - AVPlayer + AVVideoCompositing session

final class NativeVideoEngineSession: NSObject {
  let textureId: Int64
  let renderWidth: Int
  let renderHeight: Int

  private let texture: EngineFrameTexture
  private let registrar: FlutterPluginRegistrar
  private let player: AVPlayer
  private let videoOutput: AVPlayerItemVideoOutput
  private var displayLink: CADisplayLink?
  private let duration: CMTime
  private let preferredTransform: CGAffineTransform
  private let onEvent: ([String: Any]) -> Void
  private var didComplete = false

  init(
    registrar: FlutterPluginRegistrar,
    sourcePath: String,
    outgoingStart: CMTime,
    outgoingEnd: CMTime,
    incomingStart: CMTime,
    incomingEnd: CMTime,
    duration: CMTime,
    effect: String,
    kind: String,
    reverse: Bool,
    layers: [ExportMotion],
    incomingScaleFrom: CGFloat,
    incomingScaleTo: CGFloat,
    wipeEdge: String = "",
    onEvent: @escaping ([String: Any]) -> Void
  ) throws {
    self.registrar = registrar
    self.duration = duration
    self.onEvent = onEvent

    let asset = AVURLAsset(url: URL(fileURLWithPath: sourcePath))
    let composition = AVMutableComposition()
    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
      throw NSError(domain: "NativeVideoEngine", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "No video track",
      ])
    }
    preferredTransform = videoTrack.preferredTransform

    let outComp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 1)!
    let inComp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 2)!
    try outComp.insertTimeRange(CMTimeRange(start: outgoingStart, end: outgoingEnd), of: videoTrack, at: .zero)
    try inComp.insertTimeRange(CMTimeRange(start: incomingStart, end: incomingEnd), of: videoTrack, at: .zero)
    // Stretch each half-handle across the full transition so before-cut and
    // after-cut frames stay different for the whole dissolve (matches export).
    let outInserted = CMTimeRange(start: .zero, duration: CMTimeSubtract(outgoingEnd, outgoingStart))
    let inInserted = CMTimeRange(start: .zero, duration: CMTimeSubtract(incomingEnd, incomingStart))
    if CMTIME_IS_NUMERIC(outInserted.duration), CMTimeCompare(outInserted.duration, duration) != 0 {
      outComp.scaleTimeRange(outInserted, toDuration: duration)
    }
    if CMTIME_IS_NUMERIC(inInserted.duration), CMTimeCompare(inInserted.duration, duration) != 0 {
      inComp.scaleTimeRange(inInserted, toDuration: duration)
    }
    outComp.preferredTransform = preferredTransform
    inComp.preferredTransform = preferredTransform

    // Source audio during the transition window (outgoing + incoming overlap).
    if let audioTrack = asset.tracks(withMediaType: .audio).first {
      let outAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 3)
      let inAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 4)
      try? outAudio?.insertTimeRange(CMTimeRange(start: outgoingStart, end: outgoingEnd), of: audioTrack, at: .zero)
      try? inAudio?.insertTimeRange(CMTimeRange(start: incomingStart, end: incomingEnd), of: audioTrack, at: .zero)
      if let outAudio {
        let range = CMTimeRange(start: .zero, duration: CMTimeSubtract(outgoingEnd, outgoingStart))
        if CMTIME_IS_NUMERIC(range.duration), CMTimeCompare(range.duration, duration) != 0 {
          outAudio.scaleTimeRange(range, toDuration: duration)
        }
      }
      if let inAudio {
        let range = CMTimeRange(start: .zero, duration: CMTimeSubtract(incomingEnd, incomingStart))
        if CMTIME_IS_NUMERIC(range.duration), CMTimeCompare(range.duration, duration) != 0 {
          inAudio.scaleTimeRange(range, toDuration: duration)
        }
      }
    }

    let natural = videoTrack.naturalSize.applying(preferredTransform)
    let oriented = CGSize(width: abs(natural.width), height: abs(natural.height))
    let scale = min(1.0, 720.0 / max(oriented.width, 1))
    let outputSize = CGSize(
      width: max(2, floor(oriented.width * scale / 2) * 2),
      height: max(2, floor(oriented.height * scale / 2) * 2)
    )
    renderWidth = Int(outputSize.width)
    renderHeight = Int(outputSize.height)

    let baseTransform = exportFitTransform(
      track: videoTrack,
      renderSize: outputSize,
      rotationDegrees: 0
    )
    let instruction = ExportCompositionInstruction(
      timeRange: CMTimeRange(start: .zero, duration: duration),
      outgoingTrackID: outComp.trackID,
      incomingTrackID: inComp.trackID,
      effect: effect,
      kind: kind,
      reverse: reverse,
      layers: layers,
      preferredTransform: baseTransform,
      incomingScaleFrom: incomingScaleFrom,
      incomingScaleTo: incomingScaleTo,
      wipeEdge: wipeEdge
    )

    let videoComposition = AVMutableVideoComposition()
    videoComposition.customVideoCompositorClass = ExportFrameCompositor.self
    videoComposition.instructions = [instruction]
    videoComposition.renderSize = outputSize
    videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

    let item = AVPlayerItem(asset: composition)
    item.videoComposition = videoComposition
    item.seekingWaitsForVideoCompositionRendering = true
    item.audioTimePitchAlgorithm = .spectral

    let attrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
    item.add(videoOutput)

    player = AVPlayer(playerItem: item)
    player.actionAtItemEnd = .pause

    texture = EngineFrameTexture()
    textureId = registrar.textures().register(texture)
    super.init()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(itemDidEnd),
      name: .AVPlayerItemDidPlayToEndTime,
      object: item
    )
    let link = CADisplayLink(target: self, selector: #selector(onDisplayLink))
    if #available(iOS 15.0, *) {
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
    } else {
      link.preferredFramesPerSecond = 30
    }
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  convenience init(
    registrar: FlutterPluginRegistrar,
    item: AVPlayerItem,
    renderSize: CGSize,
    onEvent: @escaping ([String: Any]) -> Void
  ) {
    let attrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
    item.add(output)
    let player = AVPlayer(playerItem: item)
    player.actionAtItemEnd = .pause
    let texture = EngineFrameTexture()
    let textureId = registrar.textures().register(texture)
    self.init(
      textureId: textureId,
      renderWidth: Int(renderSize.width),
      renderHeight: Int(renderSize.height),
      texture: texture,
      registrar: registrar,
      player: player,
      videoOutput: output,
      duration: item.duration,
      onEvent: onEvent
    )
  }

  private init(
    textureId: Int64,
    renderWidth: Int,
    renderHeight: Int,
    texture: EngineFrameTexture,
    registrar: FlutterPluginRegistrar,
    player: AVPlayer,
    videoOutput: AVPlayerItemVideoOutput,
    duration: CMTime,
    onEvent: @escaping ([String: Any]) -> Void
  ) {
    self.textureId = textureId
    self.renderWidth = renderWidth
    self.renderHeight = renderHeight
    self.texture = texture
    self.registrar = registrar
    self.player = player
    self.videoOutput = videoOutput
    self.duration = duration
    self.preferredTransform = .identity
    self.onEvent = onEvent
    super.init()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(itemDidEnd),
      name: .AVPlayerItemDidPlayToEndTime,
      object: player.currentItem
    )
    let link = CADisplayLink(target: self, selector: #selector(onDisplayLink))
    if #available(iOS 15.0, *) {
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
    } else {
      link.preferredFramesPerSecond = 30
    }
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  func play() {
    didComplete = false
    player.play()
    onEvent(["type": "playing", "playing": true])
  }

  func pause() {
    player.pause()
    onEvent(["type": "playing", "playing": false])
  }

  func seek(toMs ms: Int, completion: @escaping (Bool) -> Void) {
    let t = CMTime(value: CMTimeValue(max(0, ms)), timescale: 1000)
    player.pause()
    player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
      guard let self else {
        DispatchQueue.main.async { completion(false) }
        return
      }
      let landed = Int((CMTimeGetSeconds(self.player.currentTime()) * 1000).rounded())
      self.onEvent(["type": "position", "positionMs": landed])
      DispatchQueue.main.async { completion(finished) }
    }
  }

  func preroll(toMs ms: Int, completion: @escaping (Bool) -> Void) {
    let target = CMTime(value: CMTimeValue(max(0, ms)), timescale: 1000)
    player.pause()
    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
      guard let self, finished else {
        DispatchQueue.main.async { completion(false) }
        return
      }
      self.pullFrame(retries: 24) { ok in
        self.onEvent(["type": "position", "positionMs": ms])
        completion(ok)
      }
    }
  }

  func dispose() {
    displayLink?.invalidate()
    displayLink = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    registrar.textures().unregisterTexture(textureId)
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func itemDidEnd() {
    guard !didComplete else { return }
    didComplete = true
    onEvent(["type": "completed"])
    onEvent(["type": "playing", "playing": false])
  }

  @objc private func onDisplayLink() {
    _ = pullFrameOnce()
    let seconds = CMTimeGetSeconds(player.currentTime())
    if seconds.isFinite {
      onEvent(["type": "position", "positionMs": Int((seconds * 1000).rounded())])
    }
  }

  private func pullFrame(retries: Int, completion: @escaping (Bool) -> Void) {
    if pullFrameOnce() {
      completion(true)
      return
    }
    guard retries > 0 else {
      completion(texture.pixelBuffer != nil)
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
      self?.pullFrame(retries: retries - 1, completion: completion)
    }
  }

  @discardableResult
  private func pullFrameOnce() -> Bool {
    let itemTime = player.currentTime()
    guard itemTime.isValid, !itemTime.isIndefinite else { return false }
    // Prefer exact item time after seek; fall back to host-mapped time while playing.
    let candidates: [CMTime] = [
      itemTime,
      videoOutput.itemTime(forHostTime: CACurrentMediaTime()),
    ]
    for t in candidates {
      if videoOutput.hasNewPixelBuffer(forItemTime: t),
         let buffer = videoOutput.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
        texture.pixelBuffer = buffer
        registrar.textures().textureFrameAvailable(textureId)
        return true
      }
    }
    // Force a copy even without the "new" flag after seek (compositor may already have the frame).
    if let buffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
      texture.pixelBuffer = buffer
      registrar.textures().textureFrameAvailable(textureId)
      return true
    }
    return false
  }
}

final class EngineFrameTexture: NSObject, FlutterTexture {
  var pixelBuffer: CVPixelBuffer?
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    guard let pixelBuffer else { return nil }
    return Unmanaged.passRetained(pixelBuffer)
  }
}

final class TransitionCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
  let timeRange: CMTimeRange
  let enablePostProcessing = false
  let containsTweening = true
  let requiredSourceTrackIDs: [NSValue]?
  let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
  let outgoingTrackID: CMPersistentTrackID
  let incomingTrackID: CMPersistentTrackID
  let effect: String
  let renderSize: CGSize
  let preferredTransform: CGAffineTransform

  init(
    timeRange: CMTimeRange,
    outgoingTrackID: CMPersistentTrackID,
    incomingTrackID: CMPersistentTrackID,
    effect: String,
    renderSize: CGSize,
    preferredTransform: CGAffineTransform
  ) {
    self.timeRange = timeRange
    self.outgoingTrackID = outgoingTrackID
    self.incomingTrackID = incomingTrackID
    self.effect = effect
    self.renderSize = renderSize
    self.preferredTransform = preferredTransform
    requiredSourceTrackIDs = [
      NSNumber(value: outgoingTrackID),
      NSNumber(value: incomingTrackID),
    ]
    super.init()
  }
}

/// Metal-backed frame compositor plugged into AVVideoComposition.
final class MetalTransitionCompositor: NSObject, AVVideoCompositing {
  private let renderer = MetalSlideRenderer()
  private var renderContext: AVVideoCompositionRenderContext?

  var sourcePixelBufferAttributes: [String: Any]? = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
  ]
  var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
  ]

  func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
    renderContext = newRenderContext
  }

  func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
    guard let instruction = request.videoCompositionInstruction as? TransitionCompositionInstruction,
          let outBuf = request.sourceFrame(byTrackID: instruction.outgoingTrackID),
          let inBuf = request.sourceFrame(byTrackID: instruction.incomingTrackID),
          let dst = request.renderContext.newPixelBuffer()
    else {
      request.finish(with: NSError(domain: "MetalTransitionCompositor", code: 2))
      return
    }

    let duration = CMTimeGetSeconds(instruction.timeRange.duration)
    let t = duration > 0
      ? min(max(CMTimeGetSeconds(request.compositionTime) / duration, 0), 1)
      : 1

    do {
      try renderer.render(
        outgoing: outBuf,
        incoming: inBuf,
        destination: dst,
        progress: CGFloat(t),
        effect: instruction.effect,
        preferredTransform: instruction.preferredTransform
      )
      request.finish(withComposedVideoFrame: dst)
    } catch {
      request.finish(with: error)
    }
  }

  func cancelAllPendingVideoCompositionRequests() {}
}

/// iMovie-style slide / push / cover using Metal (CIContext on MTLDevice).
final class MetalSlideRenderer {
  private let ciContext: CIContext

  init() {
    let device = MTLCreateSystemDefaultDevice()!
    ciContext = CIContext(mtlDevice: device, options: [
      .cacheIntermediates: false,
      .useSoftwareRenderer: false,
    ])
  }

  func render(
    outgoing: CVPixelBuffer,
    incoming: CVPixelBuffer,
    destination: CVPixelBuffer,
    progress t: CGFloat,
    effect: String,
    preferredTransform: CGAffineTransform
  ) throws {
    let w = CGFloat(CVPixelBufferGetWidth(destination))
    let h = CGFloat(CVPixelBufferGetHeight(destination))
    let target = CGRect(x: 0, y: 0, width: w, height: h)

    var outImage = fit(orient(CIImage(cvPixelBuffer: outgoing), preferredTransform), into: target)
    var inImage = fit(orient(CIImage(cvPixelBuffer: incoming), preferredTransform), into: target)

    let (outTx, inTx) = offsets(effect: effect, t: t, width: w, height: h)
    outImage = outImage.transformed(by: CGAffineTransform(translationX: outTx.x, y: outTx.y))
    inImage = inImage.transformed(by: CGAffineTransform(translationX: inTx.x, y: inTx.y))

    let canvas = CIImage(color: .black).cropped(to: target)
    let composed = inImage.composited(over: outImage.composited(over: canvas))
    ciContext.render(composed, to: destination)
  }

  private func orient(_ image: CIImage, _ transform: CGAffineTransform) -> CIImage {
    var img = image.transformed(by: transform)
    let e = img.extent
    return img.transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
  }

  private func fit(_ image: CIImage, into target: CGRect) -> CIImage {
    var img = image
    var e = img.extent
    let scale = max(target.width / max(e.width, 1), target.height / max(e.height, 1))
    img = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    e = img.extent
    let tx = (target.width - e.width) / 2 - e.origin.x
    let ty = (target.height - e.height) / 2 - e.origin.y
    return img.transformed(by: CGAffineTransform(translationX: tx, y: ty)).cropped(to: target)
  }

  private func offsets(
    effect: String,
    t: CGFloat,
    width: CGFloat,
    height: CGFloat
  ) -> (CGPoint, CGPoint) {
    switch effect.lowercased() {
    // Cover: outgoing stays; incoming slides over (iMovie Cover).
    case "coverleft":
      return (.zero, CGPoint(x: width * (1 - t), y: 0))
    case "coverright":
      return (.zero, CGPoint(x: -width * (1 - t), y: 0))
    case "coverup":
      return (.zero, CGPoint(x: 0, y: -height * (1 - t)))
    case "coverdown":
      return (.zero, CGPoint(x: 0, y: height * (1 - t)))
    // Slide / Push: both layers move (iMovie Slide / Push conveyor).
    case "slideleft", "pushleft":
      return (CGPoint(x: -width * t, y: 0), CGPoint(x: width * (1 - t), y: 0))
    case "slideright", "pushright":
      return (CGPoint(x: width * t, y: 0), CGPoint(x: -width * (1 - t), y: 0))
    case "slideup", "pushup":
      return (CGPoint(x: 0, y: height * t), CGPoint(x: 0, y: -height * (1 - t)))
    case "slidedown", "pushdown":
      return (CGPoint(x: 0, y: -height * t), CGPoint(x: 0, y: height * (1 - t)))
    default:
      return (CGPoint(x: -width * t, y: 0), CGPoint(x: width * (1 - t), y: 0))
    }
  }
}
