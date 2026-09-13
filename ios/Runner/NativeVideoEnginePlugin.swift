import AVFoundation
import CoreImage
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
        let session = try NativeVideoEngineSession(
          registrar: registrar,
          sourcePath: sourcePath,
          outgoingStart: CMTime(value: CMTimeValue(outStartMs), timescale: 1000),
          outgoingEnd: CMTime(value: CMTimeValue(outEndMs), timescale: 1000),
          incomingStart: CMTime(value: CMTimeValue(inStartMs), timescale: 1000),
          incomingEnd: CMTime(value: CMTimeValue(inEndMs), timescale: 1000),
          duration: CMTime(value: CMTimeValue(durationMs), timescale: 1000),
          effect: effect,
          onEvent: { [weak self] event in self?.eventSink?(event) }
        )
        self.session = session
        result(["textureId": session.textureId, "durationMs": durationMs])
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

// MARK: - AVFoundation session

final class NativeVideoEngineSession: NSObject {
  let textureId: Int64
  private let texture: EngineFrameTexture
  private let registrar: FlutterPluginRegistrar
  private let player: AVPlayer
  private let videoOutput: AVPlayerItemVideoOutput
  private var displayLink: CADisplayLink?
  private let duration: CMTime
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

    let outComp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 1)!
    let inComp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 2)!
    try outComp.insertTimeRange(CMTimeRange(start: outgoingStart, end: outgoingEnd), of: videoTrack, at: .zero)
    try inComp.insertTimeRange(CMTimeRange(start: incomingStart, end: incomingEnd), of: videoTrack, at: .zero)

    if let audioTrack = asset.tracks(withMediaType: .audio).first {
      let outAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 3)
      let inAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 4)
      try? outAudio?.insertTimeRange(CMTimeRange(start: outgoingStart, end: outgoingEnd), of: audioTrack, at: .zero)
      try? inAudio?.insertTimeRange(CMTimeRange(start: incomingStart, end: incomingEnd), of: audioTrack, at: .zero)
    }

    let natural = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
    let renderSize = CGSize(width: abs(natural.width), height: abs(natural.height))
    let scale = min(1.0, 720.0 / max(renderSize.width, 1))
    let outputSize = CGSize(
      width: floor(renderSize.width * scale),
      height: floor(renderSize.height * scale)
    )

    let instruction = TransitionCompositionInstruction(
      timeRange: CMTimeRange(start: .zero, duration: duration),
      outgoingTrackID: outComp.trackID,
      incomingTrackID: inComp.trackID,
      effect: effect,
      renderSize: outputSize
    )

    let videoComposition = AVMutableVideoComposition()
    videoComposition.customVideoCompositorClass = MetalTransitionCompositor.self
    videoComposition.instructions = [instruction]
    videoComposition.renderSize = outputSize
    videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

    let item = AVPlayerItem(asset: composition)
    item.videoComposition = videoComposition

    let attrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
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

  func seek(toMs ms: Int) {
    player.seek(
      to: CMTime(value: CMTimeValue(ms), timescale: 1000),
      toleranceBefore: .zero,
      toleranceAfter: .zero
    )
    onEvent(["type": "position", "positionMs": ms])
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
  }

  @objc private func onDisplayLink() {
    let hostTime = CACurrentMediaTime()
    let itemTime = videoOutput.itemTime(forHostTime: hostTime)
    if videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
       let buffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
      texture.pixelBuffer = buffer
      registrar.textures().textureFrameAvailable(textureId)
    }
    let seconds = CMTimeGetSeconds(player.currentTime())
    if seconds.isFinite {
      onEvent(["type": "position", "positionMs": Int((seconds * 1000).rounded())])
    }
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

  init(
    timeRange: CMTimeRange,
    outgoingTrackID: CMPersistentTrackID,
    incomingTrackID: CMPersistentTrackID,
    effect: String,
    renderSize: CGSize
  ) {
    self.timeRange = timeRange
    self.outgoingTrackID = outgoingTrackID
    self.incomingTrackID = incomingTrackID
    self.effect = effect
    self.renderSize = renderSize
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
        effect: instruction.effect
      )
      request.finish(withComposedVideoFrame: dst)
    } catch {
      request.finish(with: error)
    }
  }
}

/// GPU slide/push conveyor using Metal (CIContext on MTLDevice).
final class MetalSlideRenderer {
  private let device: MTLDevice
  private let ciContext: CIContext

  init() {
    let device = MTLCreateSystemDefaultDevice()!
    self.device = device
    self.ciContext = CIContext(mtlDevice: device, options: [
      .cacheIntermediates: false,
      .useSoftwareRenderer: false,
    ])
  }

  func render(
    outgoing: CVPixelBuffer,
    incoming: CVPixelBuffer,
    destination: CVPixelBuffer,
    progress t: CGFloat,
    effect: String
  ) throws {
    let w = CGFloat(CVPixelBufferGetWidth(destination))
    let h = CGFloat(CVPixelBufferGetHeight(destination))

    var outImage = CIImage(cvPixelBuffer: outgoing)
    var inImage = CIImage(cvPixelBuffer: incoming)
    let outExtent = outImage.extent
    let inExtent = inImage.extent
    if outExtent.width > 0, outExtent.height > 0 {
      outImage = outImage.transformed(by: CGAffineTransform(
        scaleX: w / outExtent.width,
        y: h / outExtent.height
      ))
    }
    if inExtent.width > 0, inExtent.height > 0 {
      inImage = inImage.transformed(by: CGAffineTransform(
        scaleX: w / inExtent.width,
        y: h / inExtent.height
      ))
    }

    let (outTx, inTx) = offsets(effect: effect, t: t, width: w, height: h)
    outImage = outImage.transformed(by: CGAffineTransform(translationX: outTx.x, y: outTx.y))
    inImage = inImage.transformed(by: CGAffineTransform(translationX: inTx.x, y: inTx.y))

    let canvas = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    let composed = inImage.composited(over: outImage.composited(over: canvas))
    ciContext.render(composed, to: destination)
  }

  private func offsets(
    effect: String,
    t: CGFloat,
    width: CGFloat,
    height: CGFloat
  ) -> (CGPoint, CGPoint) {
    switch effect.lowercased() {
    case "slideleft", "pushleft", "coverleft":
      return (CGPoint(x: -width * t, y: 0), CGPoint(x: width * (1 - t), y: 0))
    case "slideright", "pushright", "coverright":
      return (CGPoint(x: width * t, y: 0), CGPoint(x: -width * (1 - t), y: 0))
    case "slideup", "pushup", "coverup":
      return (CGPoint(x: 0, y: height * t), CGPoint(x: 0, y: -height * (1 - t)))
    case "slidedown", "pushdown", "coverdown":
      return (CGPoint(x: 0, y: -height * t), CGPoint(x: 0, y: height * (1 - t)))
    default:
      return (CGPoint(x: -width * t, y: 0), CGPoint(x: width * (1 - t), y: 0))
    }
  }
}
