import AVFoundation
import Accelerate
import Flutter
import UIKit

// MARK: - Probe / waveform / export (AVFoundation + VideoToolbox)

enum NativeVideoEngineMedia {
  static func probe(path: String) throws -> [String: Any] {
    let url = URL(fileURLWithPath: path)
    let asset = AVURLAsset(url: url)
    let video = asset.tracks(withMediaType: .video).first
    let audio = asset.tracks(withMediaType: .audio).first
    var width = 1080
    var height = 1920
    if let video {
      let size = video.naturalSize.applying(video.preferredTransform)
      width = Int(abs(size.width).rounded())
      height = Int(abs(size.height).rounded())
    }
    let durationMs = Int((CMTimeGetSeconds(asset.duration) * 1000).rounded())
    return [
      "hasAudio": audio != nil,
      "durationMs": max(0, durationMs),
      "width": max(1, width),
      "height": max(1, height),
    ]
  }

  static func decodeWaveform(path: String, peakCount: Int) throws -> [String: Any] {
    let url = URL(fileURLWithPath: path)
    // Prefer AVAudioFile for pure audio; fall back to AVAssetReader for video.
    if let fileResult = try? decodeWaveformAudioFile(url: url, peakCount: peakCount) {
      return fileResult
    }
    return try decodeWaveformAssetReader(url: url, peakCount: peakCount)
  }

  private static func decodeWaveformAudioFile(url: URL, peakCount: Int) throws -> [String: Any] {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let frameCount = AVAudioFrameCount(file.length)
    guard frameCount > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
    else {
      throw NSError(domain: "NativeVideoEngine", code: 10)
    }
    try file.read(into: buffer)
    return peaksFromBuffer(buffer, peakCount: peakCount, sampleRate: format.sampleRate)
  }

  private static func decodeWaveformAssetReader(url: URL, peakCount: Int) throws -> [String: Any] {
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .audio).first else {
      return ["peaks": [Double](repeating: 0.05, count: max(1, peakCount)), "durationMs": 0]
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ]
    )
    reader.add(output)
    reader.startReading()

    var samples = [Int16]()
    samples.reserveCapacity(64_000)
    while let sample = output.copyNextSampleBuffer() {
      guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
      var length = 0
      var dataPointer: UnsafeMutablePointer<Int8>?
      CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
      if let dataPointer, length >= 2 {
        let count = length / 2
        dataPointer.withMemoryRebound(to: Int16.self, capacity: count) { ptr in
          for i in 0..<count {
            if samples.count >= 250_000 { break }
            samples.append(ptr[i])
          }
        }
      }
      if samples.count >= 250_000 { break }
    }

    let durationMs = Int((CMTimeGetSeconds(asset.duration) * 1000).rounded())
    if samples.isEmpty {
      return ["peaks": [Double](repeating: 0.05, count: max(1, peakCount)), "durationMs": durationMs]
    }
    let buckets = max(1, peakCount)
    let bucketSize = max(1, samples.count / buckets)
    var peaks = [Double](repeating: 0, count: buckets)
    var tallest = 0.0
    for i in 0..<buckets {
      let start = i * bucketSize
      if start >= samples.count { break }
      let end = min(start + bucketSize, samples.count)
      var maxAbs = 0
      for s in start..<end {
        maxAbs = max(maxAbs, abs(Int(samples[s])))
      }
      let v = (Double(maxAbs) / 32768.0).clamped(to: 0...1)
      peaks[i] = v
      tallest = max(tallest, v)
    }
    if tallest > 0.05 {
      for i in 0..<peaks.count {
        peaks[i] = (peaks[i] / tallest).clamped(to: 0...1)
      }
    }
    return ["peaks": peaks, "durationMs": durationMs]
  }

  private static func peaksFromBuffer(
    _ buffer: AVAudioPCMBuffer,
    peakCount: Int,
    sampleRate: Double
  ) -> [String: Any] {
    let channels = Int(buffer.format.channelCount)
    let frames = Int(buffer.frameLength)
    guard frames > 0, let data = buffer.floatChannelData else {
      return ["peaks": [Double](), "durationMs": 0]
    }
    let mono = [Float](unsafeUninitializedCapacity: frames) { dest, count in
      for i in 0..<frames {
        var sum: Float = 0
        for c in 0..<channels {
          sum += abs(data[c][i])
        }
        dest[i] = sum / Float(max(channels, 1))
      }
      count = frames
    }
    let buckets = max(1, peakCount)
    let bucketSize = max(1, frames / buckets)
    var peaks = [Double](repeating: 0, count: buckets)
    var tallest = 0.0
    for i in 0..<buckets {
      let start = i * bucketSize
      if start >= frames { break }
      let end = min(start + bucketSize, frames)
      var maxAbs: Float = 0
      for s in start..<end {
        maxAbs = max(maxAbs, mono[s])
      }
      let v = Double(maxAbs).clamped(to: 0...1)
      peaks[i] = v
      tallest = max(tallest, v)
    }
    if tallest > 0.05 {
      for i in 0..<peaks.count {
        peaks[i] = (peaks[i] / tallest).clamped(to: 0...1)
      }
    }
    let durationMs = Int((Double(frames) / sampleRate) * 1000)
    return ["peaks": peaks, "durationMs": durationMs]
  }

  static func export(
    args: [String: Any],
    onProgress: @escaping (Double) -> Void,
    completion: @escaping (Result<String, Error>) -> Void
  ) {
    do {
      let request = try ExportRequest(args: args)
      if request.streamCopy {
        try exportStreamCopy(request: request, onProgress: onProgress, completion: completion)
      } else {
        try exportReencode(request: request, onProgress: onProgress, completion: completion)
      }
    } catch {
      completion(.failure(error))
    }
  }
}

private extension Comparable {
  func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}

private struct ExportRequest {
  let sourcePath: String
  let outputPath: String
  let width: Int
  let height: Int
  let rotationDegrees: Double
  let durationMs: Int
  let streamCopy: Bool
  let hasVideoAudio: Bool
  let segments: [[String: Any]]
  let overlays: [[String: Any]]
  let music: [[String: Any]]

  init(args: [String: Any]) throws {
    guard let sourcePath = args["sourcePath"] as? String,
          let outputPath = args["outputPath"] as? String
    else {
      throw NSError(domain: "NativeVideoEngine", code: 20, userInfo: [
        NSLocalizedDescriptionKey: "Missing export paths",
      ])
    }
    self.sourcePath = sourcePath
    self.outputPath = outputPath
    width = args["width"] as? Int ?? 1080
    height = args["height"] as? Int ?? 1920
    rotationDegrees = args["rotationDegrees"] as? Double ?? 0
    durationMs = args["durationMs"] as? Int ?? 0
    streamCopy = args["streamCopy"] as? Bool ?? false
    hasVideoAudio = args["hasVideoAudio"] as? Bool ?? true
    segments = args["segments"] as? [[String: Any]] ?? []
    overlays = args["overlays"] as? [[String: Any]] ?? []
    music = args["music"] as? [[String: Any]] ?? []
  }
}

private func exportStreamCopy(
  request: ExportRequest,
  onProgress: @escaping (Double) -> Void,
  completion: @escaping (Result<String, Error>) -> Void
) throws {
  let asset = AVURLAsset(url: URL(fileURLWithPath: request.sourcePath))
  guard let segment = request.segments.first,
        let startMs = segment["startMs"] as? Int,
        let endMs = segment["endMs"] as? Int,
        let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)
  else {
    throw NSError(domain: "NativeVideoEngine", code: 21, userInfo: [
      NSLocalizedDescriptionKey: "Passthrough export unavailable",
    ])
  }
  try? FileManager.default.removeItem(atPath: request.outputPath)
  session.outputURL = URL(fileURLWithPath: request.outputPath)
  session.outputFileType = .mp4
  let start = CMTime(value: CMTimeValue(startMs), timescale: 1000)
  let duration = CMTime(value: CMTimeValue(max(0, endMs - startMs)), timescale: 1000)
  session.timeRange = CMTimeRange(start: start, duration: duration)

  let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { t in
    onProgress(Double(session.progress))
    if session.status != .exporting { t.invalidate() }
  }
  session.exportAsynchronously {
    timer.invalidate()
    switch session.status {
    case .completed:
      onProgress(1)
      completion(.success(request.outputPath))
    default:
      completion(.failure(session.error ?? NSError(domain: "NativeVideoEngine", code: 22)))
    }
  }
}

private func exportReencode(
  request: ExportRequest,
  onProgress: @escaping (Double) -> Void,
  completion: @escaping (Result<String, Error>) -> Void
) throws {
  let source = AVURLAsset(url: URL(fileURLWithPath: request.sourcePath))
  guard let sourceVideo = source.tracks(withMediaType: .video).first else {
    throw NSError(domain: "NativeVideoEngine", code: 23, userInfo: [
      NSLocalizedDescriptionKey: "No video track",
    ])
  }

  let composition = AVMutableComposition()
  // Two video tracks so overlapping transition windows can composite.
  let videoTracks = [
    composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!,
    composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!,
  ]
  // Keep audio on one track without overlap so transitions don't double volume.
  let compAudio = request.hasVideoAudio
    ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    : nil
  let sourceAudio = source.tracks(withMediaType: .audio).first

  let placements = try packTransitionPlacements(
    segments: request.segments,
    sourceVideo: sourceVideo,
    videoTracks: videoTracks,
    sourceAudio: sourceAudio,
    compAudio: compAudio
  )

  for clip in request.music {
    guard let path = clip["path"] as? String else { continue }
    let musicAsset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let musicTrack = musicAsset.tracks(withMediaType: .audio).first,
          let dest = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
          )
    else { continue }
    let offsetMs = clip["sourceOffsetMs"] as? Int ?? 0
    let durationMs = clip["durationMs"] as? Int ?? 0
    let timelineMs = clip["timelineStartMs"] as? Int ?? 0
    let srcRange = CMTimeRange(
      start: CMTime(value: CMTimeValue(offsetMs), timescale: 1000),
      duration: CMTime(value: CMTimeValue(durationMs), timescale: 1000)
    )
    let at = CMTime(value: CMTimeValue(timelineMs), timescale: 1000)
    try? dest.insertTimeRange(srcRange, of: musicTrack, at: at)
  }

  let renderSize = CGSize(width: request.width, height: request.height)
  let baseTransform = exportFitTransform(
    track: sourceVideo,
    renderSize: renderSize,
    rotationDegrees: request.rotationDegrees
  )

  let videoComp = AVMutableVideoComposition()
  videoComp.renderSize = renderSize
  videoComp.frameDuration = CMTime(value: 1, timescale: 30)
  let needsCompositor = placements.contains { $0.transitionMs > 0 }
  if needsCompositor {
    // Core Animation tools cannot be combined with a custom compositor.
    ExportOverlayStore.set(request.overlays)
    videoComp.customVideoCompositorClass = ExportFrameCompositor.self
    videoComp.instructions = buildCustomExportInstructions(
      placements: placements,
      videoTracks: videoTracks,
      baseTransform: baseTransform
    )
  } else {
    ExportOverlayStore.clear()
    videoComp.instructions = buildExportInstructions(
      placements: placements,
      videoTracks: videoTracks,
      baseTransform: baseTransform,
      renderSize: renderSize
    )
  }

  if !needsCompositor && !request.overlays.isEmpty {
    let parent = CALayer()
    let videoLayer = CALayer()
    parent.frame = CGRect(origin: .zero, size: renderSize)
    videoLayer.frame = parent.frame
    parent.addSublayer(videoLayer)

    for overlay in request.overlays {
      let image: UIImage?
      if let path = overlay["path"] as? String {
        image = UIImage(contentsOfFile: path)
      } else if let dir = overlay["sequenceDir"] as? String,
                let count = overlay["frameCount"] as? Int,
                count > 0 {
        let last = String(format: "%@/frame_%04d.png", dir, count)
        image = UIImage(contentsOfFile: last)
      } else {
        image = nil
      }
      guard let image else { continue }
      let layer = CALayer()
      layer.contents = image.cgImage
      layer.frame = parent.frame
      layer.opacity = 0
      if let spans = overlay["spans"] as? [[String: Any]] {
        for span in spans {
          let startMs = span["startMs"] as? Int ?? 0
          let endMs = span["endMs"] as? Int ?? 0
          let anim = CABasicAnimation(keyPath: "opacity")
          anim.fromValue = 1
          anim.toValue = 1
          anim.beginTime = AVCoreAnimationBeginTimeAtZero + Double(startMs) / 1000.0
          anim.duration = max(0.001, Double(endMs - startMs) / 1000.0)
          anim.fillMode = .forwards
          anim.isRemovedOnCompletion = false
          layer.add(anim, forKey: "opacity-\(startMs)")
        }
      }
      parent.addSublayer(layer)
    }
    parent.isGeometryFlipped = true
    videoComp.animationTool = AVVideoCompositionCoreAnimationTool(
      postProcessingAsVideoLayer: videoLayer,
      in: parent
    )
  }

  try? FileManager.default.removeItem(atPath: request.outputPath)
  guard let session = AVAssetExportSession(
    asset: composition,
    presetName: AVAssetExportPresetHighestQuality
  ) else {
    throw NSError(domain: "NativeVideoEngine", code: 24, userInfo: [
      NSLocalizedDescriptionKey: "Export session unavailable",
    ])
  }
  session.outputURL = URL(fileURLWithPath: request.outputPath)
  session.outputFileType = .mp4
  session.videoComposition = videoComp
  let videoEnd = placements.last?.end ?? composition.duration
  let requested = request.durationMs > 0
    ? CMTime(value: CMTimeValue(request.durationMs), timescale: 1000)
    : videoEnd
  let exportDuration = CMTimeMinimum(CMTimeMinimum(requested, videoEnd), composition.duration)
  session.timeRange = CMTimeRange(start: .zero, duration: exportDuration)
  for (index, instruction) in videoComp.instructions.enumerated() {
    let range = instruction.timeRange
    NSLog(
      "NativeVideoEngine instruction %d %.3f-%.3f",
      index,
      CMTimeGetSeconds(range.start),
      CMTimeGetSeconds(CMTimeRangeGetEnd(range))
    )
  }
  NSLog(
    "NativeVideoEngine export start segments=%d composition=%.3fs video=%.3fs requestedMs=%d instructions=%d compositor=%@",
    request.segments.count,
    CMTimeGetSeconds(composition.duration),
    CMTimeGetSeconds(videoEnd),
    request.durationMs,
    videoComp.instructions.count,
    needsCompositor ? "custom" : "layer"
  )

  let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { t in
    onProgress(Double(session.progress))
    if session.status != .exporting { t.invalidate() }
  }
  session.exportAsynchronously {
    timer.invalidate()
    ExportOverlayStore.clear()
    switch session.status {
    case .completed:
      onProgress(1)
      completion(.success(request.outputPath))
    default:
      let error = session.error ?? NSError(domain: "NativeVideoEngine", code: 25, userInfo: [
        NSLocalizedDescriptionKey: "Export status \(session.status.rawValue)",
      ])
      let described = describeExportError(error)
      NSLog("NativeVideoEngine export failed status=%d %@", session.status.rawValue, described)
      completion(.failure(NSError(domain: "NativeVideoEngine", code: (error as NSError).code, userInfo: [
        NSLocalizedDescriptionKey: described,
      ])))
    }
  }
}

private func describeExportError(_ error: Error) -> String {
  let ns = error as NSError
  var parts = ["\(ns.domain)(\(ns.code)): \(ns.localizedDescription)"]
  if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
    parts.append("underlying \(underlying.domain)(\(underlying.code)): \(underlying.localizedDescription)")
  }
  return parts.joined(separator: " | ")
}

private func trackHasMedia(_ track: AVAssetTrack, during range: CMTimeRange) -> Bool {
  let compositionTrack = track as? AVCompositionTrack
  let segments = compositionTrack?.segments ?? []
  for segment in segments where !segment.isEmpty {
    let intersection = CMTimeRangeGetIntersection(segment.timeMapping.target, otherRange: range)
    if CMTimeCompare(intersection.duration, .zero) > 0 {
      return true
    }
  }
  return false
}

private func exportLayerInstructions(
  tracks: [AVMutableCompositionTrack],
  timeRange: CMTimeRange,
  baseTransform: CGAffineTransform,
  opacity: Float
) -> [AVVideoCompositionLayerInstruction] {
  var layers: [AVVideoCompositionLayerInstruction] = []
  for track in tracks where trackHasMedia(track, during: timeRange) {
    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
    layer.setTransform(baseTransform, at: timeRange.start)
    layer.setOpacity(opacity, at: timeRange.start)
    layers.append(layer)
  }
  return layers
}

func exportFitTransform(
  track: AVAssetTrack,
  renderSize: CGSize,
  rotationDegrees: Double
) -> CGAffineTransform {
  let natural = track.naturalSize.applying(track.preferredTransform)
  let srcW = abs(natural.width)
  let srcH = abs(natural.height)
  let scale = max(renderSize.width / max(srcW, 1), renderSize.height / max(srcH, 1))
  var transform = track.preferredTransform
  transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
  let scaledW = srcW * scale
  let scaledH = srcH * scale
  transform = transform.concatenating(
    CGAffineTransform(translationX: (renderSize.width - scaledW) / 2, y: (renderSize.height - scaledH) / 2)
  )
  if rotationDegrees != 0 {
    let radians = CGFloat(rotationDegrees)
    transform = transform.concatenating(
      CGAffineTransform(translationX: renderSize.width / 2, y: renderSize.height / 2)
        .rotated(by: radians)
        .translatedBy(x: -renderSize.width / 2, y: -renderSize.height / 2)
    )
  }
  return transform
}

private struct ExportPlacement {
  let trackIndex: Int
  let start: CMTime
  let end: CMTime
  let transitionMs: Int
  let effect: String
  let motion: [ExportMotion]
  let kind: String
  let reverse: Bool
  let incomingScaleFrom: CGFloat
  let incomingScaleTo: CGFloat
  let wipeEdge: String
}

/// Duration-preserving packing (all transitions): composition length = A+B.
/// Centered blend [C−⌊td/2⌋, C+⌈td/2⌉) mixes **different** frames:
/// outgoing A[end−⌊td/2⌋, end) and incoming B[start, start+⌈td/2⌉),
/// each stretched across the full window (visible dissolve, no rewind).
private func cmTimeMs(_ ms: Int) -> CMTime {
  CMTime(value: CMTimeValue(max(0, ms)), timescale: 1000)
}

/// before = floor(td/2) (pre-cut), after = td - before (post-cut).
private func transitionHalfMs(_ tdMs: Int) -> (before: Int, after: Int) {
  let before = max(0, tdMs) / 2
  return (before, max(0, tdMs) - before)
}

private func packTransitionPlacements(
  segments: [[String: Any]],
  sourceVideo: AVAssetTrack,
  videoTracks: [AVMutableCompositionTrack],
  sourceAudio: AVAssetTrack?,
  compAudio: AVMutableCompositionTrack?
) throws -> [ExportPlacement] {
  var placements = [ExportPlacement]()
  var cursorMs = 0
  var prevOutTdMs = 0

  for (index, segment) in segments.enumerated() {
    let startMs = segment["startMs"] as? Int ?? 0
    let endMs = segment["endMs"] as? Int ?? startMs
    let segDurMs = max(0, endMs - startMs)
    let trackIndex = index % 2

    let outTdMs: Int
    let effect: String
    let motion: [ExportMotion]
    let kind: String
    let reverse: Bool
    let scaleFrom: CGFloat
    let scaleTo: CGFloat
    let wipeEdge: String
    if index < segments.count - 1 {
      outTdMs = max(0, segment["transitionDurationMs"] as? Int ?? 0)
      effect = (segment["transitionEffect"] as? String)?.lowercased() ?? "fade"
      motion = exportMotionLayers(segment["transitionLayers"])
      kind = (segment["transitionKind"] as? String)?.lowercased() ?? ""
      reverse = segment["transitionReverse"] as? Bool ?? false
      let params = segment["transitionParams"] as? [String: Any]
      scaleFrom = exportOptionalNumber(params?["incomingScaleFrom"]) ?? 0.84
      scaleTo = exportOptionalNumber(params?["incomingScaleTo"]) ?? 1
      wipeEdge = (params?["edge"] as? String)?.lowercased() ?? ""
    } else {
      outTdMs = 0
      effect = "fade"
      motion = []
      kind = ""
      reverse = false
      scaleFrom = 0.84
      scaleTo = 1
      wipeEdge = ""
    }

    let inHalf = transitionHalfMs(prevOutTdMs)
    let outHalf = transitionHalfMs(outTdMs)

    // Incoming half of the *previous* transition: B[start, start+after) stretched
    // across [C−before, C+after).
    if prevOutTdMs > 0, inHalf.after > 0 {
      let blendStartMs = cursorMs - inHalf.before
      let src = CMTimeRange(
        start: cmTimeMs(startMs),
        duration: cmTimeMs(inHalf.after)
      )
      try videoTracks[trackIndex].insertTimeRange(
        src,
        of: sourceVideo,
        at: cmTimeMs(blendStartMs)
      )
      videoTracks[trackIndex].scaleTimeRange(
        CMTimeRange(start: cmTimeMs(blendStartMs), duration: cmTimeMs(inHalf.after)),
        toDuration: cmTimeMs(prevOutTdMs)
      )
    }

    // Solo body at 1x between blends.
    let soloSrcStartMs = startMs + inHalf.after
    let soloSrcEndMs = endMs - outHalf.before
    let soloDurMs = max(0, soloSrcEndMs - soloSrcStartMs)
    let soloAtMs = cursorMs + inHalf.after
    if soloDurMs > 0 {
      try videoTracks[trackIndex].insertTimeRange(
        CMTimeRange(start: cmTimeMs(soloSrcStartMs), duration: cmTimeMs(soloDurMs)),
        of: sourceVideo,
        at: cmTimeMs(soloAtMs)
      )
    }

    // Outgoing half of *this* transition: A[end−before, end) stretched across
    // [C−before, C+after).
    if outTdMs > 0, outHalf.before > 0 {
      let blendStartMs = cursorMs + segDurMs - outHalf.before
      let src = CMTimeRange(
        start: cmTimeMs(endMs - outHalf.before),
        duration: cmTimeMs(outHalf.before)
      )
      try videoTracks[trackIndex].insertTimeRange(
        src,
        of: sourceVideo,
        at: cmTimeMs(blendStartMs)
      )
      videoTracks[trackIndex].scaleTimeRange(
        CMTimeRange(start: cmTimeMs(blendStartMs), duration: cmTimeMs(outHalf.before)),
        toDuration: cmTimeMs(outTdMs)
      )
    }

    // Audio stays on the hard-cut grid.
    if let compAudio, let sourceAudio, segDurMs > 0 {
      try? compAudio.insertTimeRange(
        CMTimeRange(start: cmTimeMs(startMs), duration: cmTimeMs(segDurMs)),
        of: sourceAudio,
        at: cmTimeMs(cursorMs)
      )
    }

    let mediaStartMs = prevOutTdMs > 0 ? cursorMs - inHalf.before : cursorMs
    let mediaEndMs = outTdMs > 0
      ? cursorMs + segDurMs - outHalf.before + outTdMs
      : cursorMs + segDurMs

    placements.append(
      ExportPlacement(
        trackIndex: trackIndex,
        start: cmTimeMs(mediaStartMs),
        end: cmTimeMs(mediaEndMs),
        transitionMs: outTdMs,
        effect: effect,
        motion: motion,
        kind: kind,
        reverse: reverse,
        incomingScaleFrom: scaleFrom,
        incomingScaleTo: scaleTo,
        wipeEdge: wipeEdge
      )
    )

    cursorMs += segDurMs
    prevOutTdMs = outTdMs
  }

  return placements
}

private func buildExportInstructions(
  placements: [ExportPlacement],
  videoTracks: [AVMutableCompositionTrack],
  baseTransform: CGAffineTransform,
  renderSize: CGSize
) -> [AVVideoCompositionInstructionProtocol] {
  var instructions: [AVMutableVideoCompositionInstruction] = []

  for (index, placement) in placements.enumerated() {
    let tdMs = max(0, placement.transitionMs)
    let td = cmTimeMs(tdMs)
    let hasTransition = tdMs > 0 && index < placements.count - 1
    // Duration-preserving: placement includes ±td/2 handles.
    // Solo is the body outside the centered blend [end−td, end) relative to placement.
    let incomingMs = index > 0 ? placements[index - 1].transitionMs : 0
    let soloStart = CMTimeAdd(placement.start, cmTimeMs(incomingMs))
    let soloEnd = hasTransition
      ? CMTimeSubtract(placement.end, td)
      : placement.end

    if CMTimeCompare(soloEnd, soloStart) > 0 {
      let instr = AVMutableVideoCompositionInstruction()
      instr.timeRange = CMTimeRange(
        start: soloStart,
        duration: CMTimeSubtract(soloEnd, soloStart)
      )
      // Only include tracks that actually have media in this range.
      // An empty track layer instruction makes AVAssetExportSession abort
      // ("The operation was interrupted").
      let range = instr.timeRange
      instr.layerInstructions = exportLayerInstructions(
        tracks: videoTracks,
        timeRange: range,
        baseTransform: baseTransform,
        opacity: 1
      )
      if instr.layerInstructions.isEmpty {
        let layer = AVMutableVideoCompositionLayerInstruction(
          assetTrack: videoTracks[placement.trackIndex]
        )
        layer.setTransform(baseTransform, at: range.start)
        layer.setOpacity(1, at: range.start)
        instr.layerInstructions = [layer]
      }
      instructions.append(instr)
    }

    if hasTransition {
      let next = placements[index + 1]
      let overlap = CMTimeRange(start: soloEnd, duration: td)
      if exportMotionSteps(
        motion: placement.motion,
        fromTrack: videoTracks[placement.trackIndex],
        toTrack: videoTracks[next.trackIndex],
        timeRange: overlap,
        baseTransform: baseTransform,
        renderSize: renderSize,
        into: &instructions
      ) {
        continue
      }
      let instr = AVMutableVideoCompositionInstruction()
      instr.timeRange = overlap
      instr.layerInstructions = exportTransitionLayers(
        effect: placement.effect,
        fromTrack: videoTracks[placement.trackIndex],
        toTrack: videoTracks[next.trackIndex],
        timeRange: overlap,
        baseTransform: baseTransform,
        renderSize: renderSize
      )
      instructions.append(instr)
    }
  }

  return instructions
}

struct ExportMotion {
  let property: String
  let from: CGFloat
  let to: CGFloat
  let easing: String
  let target: String
  let start: CGFloat
  let end: CGFloat
  let mode: String
}

func exportMotionLayers(_ raw: Any?) -> [ExportMotion] {
  guard let list = raw as? [Any] else { return [] }
  return list.compactMap { item in
    guard let map = item as? [String: Any],
          let property = map["property"] as? String
    else { return nil }
    let start = map["start"] == nil ? 0 : exportNumber(map["start"])
    let end = map["end"] == nil ? 1 : exportNumber(map["end"])
    return ExportMotion(
      property: property,
      from: exportNumber(map["from"]),
      to: exportNumber(map["to"]),
      easing: (map["easing"] as? String) ?? "linear",
      target: (map["target"] as? String) ?? "A",
      start: start,
      end: max(start, end),
      mode: (map["mode"] as? String)?.lowercased() ?? ""
    )
  }
}

private func exportNumber(_ value: Any?) -> CGFloat {
  if let number = value as? NSNumber { return CGFloat(number.doubleValue) }
  return 0
}

func exportOptionalNumber(_ value: Any?) -> CGFloat? {
  guard let number = value as? NSNumber else { return nil }
  return CGFloat(number.doubleValue)
}

private enum ExportOverlayStore {
  private static let lock = NSLock()
  private static var overlays: [[String: Any]] = []

  static func set(_ value: [[String: Any]]) {
    lock.lock()
    overlays = value
    lock.unlock()
  }

  static func current() -> [[String: Any]] {
    lock.lock()
    defer { lock.unlock() }
    return overlays
  }

  static func clear() {
    set([])
  }
}

private func exportEase(_ t: CGFloat, _ name: String) -> CGFloat {
  let u = min(1, max(0, t))
  switch name {
  case "easeOut":
    return 1 - pow(1 - u, 3)
  case "easeIn":
    return pow(u, 3)
  case "easeInOut":
    return u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
  default:
    return u
  }
}

private func exportMotionValue(
  _ layers: [ExportMotion],
  property: String,
  target: String,
  t: CGFloat,
  identity: CGFloat
) -> CGFloat {
  guard let layer = layers.first(where: {
    $0.property == property && ($0.target == target || $0.target == "both")
  }) else {
    return identity
  }
  let u = exportEase(t, layer.easing)
  return layer.from + (layer.to - layer.from) * u
}

/// Keyframed scale/rotation so spin is not flattened into a crossfade.
/// Returns false when the catalog has no spatial motion.
private func exportMotionSteps(
  motion: [ExportMotion],
  fromTrack: AVAssetTrack,
  toTrack: AVAssetTrack,
  timeRange: CMTimeRange,
  baseTransform: CGAffineTransform,
  renderSize: CGSize,
  into instructions: inout [AVMutableVideoCompositionInstruction]
) -> Bool {
  let spatial = motion.contains { $0.property == "scale" || $0.property == "rotation" }
  if !spatial || CMTimeCompare(timeRange.duration, .zero) <= 0 { return false }

  // Last A/B target in authored layers is on top (matches preview / dashboard).
  let outgoingOnTop = exportAOnTop(motion)
  let steps = 24

  for step in 0..<steps {
    let start = CMTimeAdd(
      timeRange.start,
      CMTimeMultiplyByRatio(timeRange.duration, multiplier: Int32(step), divisor: Int32(steps))
    )
    let end = CMTimeAdd(
      timeRange.start,
      CMTimeMultiplyByRatio(timeRange.duration, multiplier: Int32(step + 1), divisor: Int32(steps))
    )
    if CMTimeCompare(end, start) <= 0 { continue }
    let progress = CGFloat(step) / CGFloat(steps - 1)
    let outgoing = exportCenteredPose(
      baseTransform,
      scale: exportMotionValue(motion, property: "scale", target: "A", t: progress, identity: 1),
      turns: exportMotionValue(motion, property: "rotation", target: "A", t: progress, identity: 0),
      size: renderSize
    )
    let incoming = exportCenteredPose(
      baseTransform,
      scale: exportMotionValue(motion, property: "scale", target: "B", t: progress, identity: 1),
      turns: exportMotionValue(motion, property: "rotation", target: "B", t: progress, identity: 0),
      size: renderSize
    )
    let from = AVMutableVideoCompositionLayerInstruction(assetTrack: fromTrack)
    let to = AVMutableVideoCompositionLayerInstruction(assetTrack: toTrack)
    from.setTransform(outgoing, at: start)
    to.setTransform(incoming, at: start)
    from.setOpacity(1, at: start)
    to.setOpacity(1, at: start)
    let instr = AVMutableVideoCompositionInstruction()
    instr.timeRange = CMTimeRange(start: start, end: end)
    instr.layerInstructions = outgoingOnTop ? [from, to] : [to, from]
    instructions.append(instr)
  }
  NSLog("NativeVideoEngine motion steps=%d outgoingOnTop=%@", steps, outgoingOnTop ? "yes" : "no")
  return true
}

private func exportCenteredPose(
  _ base: CGAffineTransform,
  scale: CGFloat,
  turns: CGFloat,
  size: CGSize
) -> CGAffineTransform {
  let cx = size.width / 2
  let cy = size.height / 2
  return base
    .concatenating(CGAffineTransform(translationX: -cx, y: -cy))
    .concatenating(CGAffineTransform(scaleX: scale, y: scale))
    .concatenating(CGAffineTransform(rotationAngle: turns * 2 * .pi))
    .concatenating(CGAffineTransform(translationX: cx, y: cy))
}

private func exportTransitionLayers(
  effect: String,
  fromTrack: AVAssetTrack,
  toTrack: AVAssetTrack,
  timeRange: CMTimeRange,
  baseTransform: CGAffineTransform,
  renderSize: CGSize
) -> [AVVideoCompositionLayerInstruction] {
  let from = AVMutableVideoCompositionLayerInstruction(assetTrack: fromTrack)
  let to = AVMutableVideoCompositionLayerInstruction(assetTrack: toTrack)
  from.setTransform(baseTransform, at: timeRange.start)
  to.setTransform(baseTransform, at: timeRange.start)

  let w = renderSize.width
  let h = renderSize.height
  let name = effect.lowercased()

  func translated(_ tx: CGFloat, _ ty: CGFloat) -> CGAffineTransform {
    baseTransform.concatenating(CGAffineTransform(translationX: tx, y: ty))
  }

  switch name {
  case "slideleft", "pushleft":
    from.setTransformRamp(fromStart: baseTransform, toEnd: translated(-w, 0), timeRange: timeRange)
    to.setTransformRamp(fromStart: translated(w, 0), toEnd: baseTransform, timeRange: timeRange)
    from.setOpacity(1, at: timeRange.start)
    to.setOpacity(1, at: timeRange.start)
    return [to, from]

  case "slideright", "pushright":
    from.setTransformRamp(fromStart: baseTransform, toEnd: translated(w, 0), timeRange: timeRange)
    to.setTransformRamp(fromStart: translated(-w, 0), toEnd: baseTransform, timeRange: timeRange)
    from.setOpacity(1, at: timeRange.start)
    to.setOpacity(1, at: timeRange.start)
    return [to, from]

  case "slideup", "pushup":
    from.setTransformRamp(fromStart: baseTransform, toEnd: translated(0, h), timeRange: timeRange)
    to.setTransformRamp(fromStart: translated(0, -h), toEnd: baseTransform, timeRange: timeRange)
    from.setOpacity(1, at: timeRange.start)
    to.setOpacity(1, at: timeRange.start)
    return [to, from]

  case "slidedown", "pushdown":
    from.setTransformRamp(fromStart: baseTransform, toEnd: translated(0, -h), timeRange: timeRange)
    to.setTransformRamp(fromStart: translated(0, h), toEnd: baseTransform, timeRange: timeRange)
    from.setOpacity(1, at: timeRange.start)
    to.setOpacity(1, at: timeRange.start)
    return [to, from]

  case "coverleft":
    from.setOpacity(1, at: timeRange.start)
    to.setTransformRamp(fromStart: translated(w, 0), toEnd: baseTransform, timeRange: timeRange)
    to.setOpacity(1, at: timeRange.start)
    return [to, from]

  case "coverright":
    from.setOpacity(1, at: timeRange.start)
    to.setTransformRamp(fromStart: translated(-w, 0), toEnd: baseTransform, timeRange: timeRange)
    to.setOpacity(1, at: timeRange.start)
    return [to, from]

  case "coverup":
    from.setOpacity(1, at: timeRange.start)
    to.setTransformRamp(fromStart: translated(0, -h), toEnd: baseTransform, timeRange: timeRange)
    to.setOpacity(1, at: timeRange.start)
    return [to, from]

  case "coverdown":
    from.setOpacity(1, at: timeRange.start)
    to.setTransformRamp(fromStart: translated(0, h), toEnd: baseTransform, timeRange: timeRange)
    to.setOpacity(1, at: timeRange.start)
    return [to, from]

  default:
    // dissolve / fade / wipe / circle / doorway bridges → opacity crossfade.
    from.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: timeRange)
    to.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: timeRange)
    return [to, from]
  }
}

private func buildCustomExportInstructions(
  placements: [ExportPlacement],
  videoTracks: [AVMutableCompositionTrack],
  baseTransform: CGAffineTransform
) -> [AVVideoCompositionInstructionProtocol] {
  var instructions: [ExportCompositionInstruction] = []
  for (index, placement) in placements.enumerated() {
    let tdMs = max(0, placement.transitionMs)
    let td = cmTimeMs(tdMs)
    let hasTransition = tdMs > 0 && index < placements.count - 1
    // Placement includes ±td/2 handles; solo excludes the full centered blend.
    let incomingMs = index > 0 ? placements[index - 1].transitionMs : 0
    let soloStart = CMTimeAdd(placement.start, cmTimeMs(incomingMs))
    let soloEnd = hasTransition
      ? CMTimeSubtract(placement.end, td)
      : placement.end
    if CMTimeCompare(soloEnd, soloStart) > 0 {
      instructions.append(
        ExportCompositionInstruction(
          timeRange: CMTimeRange(
            start: soloStart,
            duration: CMTimeSubtract(soloEnd, soloStart)
          ),
          outgoingTrackID: videoTracks[placement.trackIndex].trackID,
          incomingTrackID: kCMPersistentTrackID_Invalid,
          effect: "",
          kind: "",
          reverse: false,
          layers: [],
          preferredTransform: baseTransform,
          incomingScaleFrom: 0.84,
          incomingScaleTo: 1
        )
      )
    }
    if hasTransition {
      let next = placements[index + 1]
      NSLog(
        "NativeVideoEngine export transition effect=%@ kind=%@ layers=%d reverse=%@",
        placement.effect,
        placement.kind,
        placement.motion.count,
        placement.reverse ? "yes" : "no"
      )
      instructions.append(
        ExportCompositionInstruction(
          timeRange: CMTimeRange(start: soloEnd, duration: td),
          outgoingTrackID: videoTracks[placement.trackIndex].trackID,
          incomingTrackID: videoTracks[next.trackIndex].trackID,
          effect: placement.effect,
          kind: placement.kind,
          reverse: placement.reverse,
          layers: placement.motion,
          preferredTransform: baseTransform,
          incomingScaleFrom: placement.incomingScaleFrom,
          incomingScaleTo: placement.incomingScaleTo,
          wipeEdge: placement.wipeEdge
        )
      )
    }
  }
  return instructions
}

func makeTimelinePreviewItem(args: [String: Any]) throws -> (item: AVPlayerItem, width: Int, height: Int) {
  guard let sourcePath = args["sourcePath"] as? String,
        let segments = args["segments"] as? [[String: Any]],
        !segments.isEmpty
  else {
    throw NSError(domain: "NativeVideoEngine", code: 30, userInfo: [
      NSLocalizedDescriptionKey: "Missing timeline",
    ])
  }
  let source = AVURLAsset(url: URL(fileURLWithPath: sourcePath))
  guard let sourceVideo = source.tracks(withMediaType: .video).first else {
    throw NSError(domain: "NativeVideoEngine", code: 31, userInfo: [
      NSLocalizedDescriptionKey: "No video track",
    ])
  }
  let composition = AVMutableComposition()
  let videoTracks = [
    composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!,
    composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!,
  ]
  let sourceAudio = source.tracks(withMediaType: .audio).first
  let compAudio = sourceAudio == nil
    ? nil
    : composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

  // Duration-preserving composition: total = A+B (hard-cut length).
  // Centered blend uses ±td/2 handles so solo→blend→solo never rewinds.
  let placements = try packTransitionPlacements(
    segments: segments,
    sourceVideo: sourceVideo,
    videoTracks: videoTracks,
    sourceAudio: sourceAudio,
    compAudio: compAudio
  )

  let natural = sourceVideo.naturalSize.applying(sourceVideo.preferredTransform)
  let oriented = CGSize(width: abs(natural.width), height: abs(natural.height))
  let fit = min(1.0, 720.0 / max(oriented.width, 1))
  let renderSize = CGSize(
    width: max(2, floor(oriented.width * fit / 2) * 2),
    height: max(2, floor(oriented.height * fit / 2) * 2)
  )
  let baseTransform = exportFitTransform(
    track: sourceVideo,
    renderSize: renderSize,
    rotationDegrees: 0
  )
  let videoComp = AVMutableVideoComposition()
  videoComp.renderSize = renderSize
  videoComp.frameDuration = CMTime(value: 1, timescale: 30)
  videoComp.customVideoCompositorClass = ExportFrameCompositor.self
  videoComp.instructions = buildCustomExportInstructions(
    placements: placements,
    videoTracks: videoTracks,
    baseTransform: baseTransform
  )
  let item = AVPlayerItem(asset: composition)
  item.videoComposition = videoComp
  item.seekingWaitsForVideoCompositionRendering = true
  return (item, Int(renderSize.width), Int(renderSize.height))
}

private func buildSourceTimePreviewInstructions(
  placements: [ExportPlacement],
  videoTracks: [AVMutableCompositionTrack],
  baseTransform: CGAffineTransform
) -> [AVVideoCompositionInstructionProtocol] {
  var instructions: [ExportCompositionInstruction] = []
  func passthrough(_ range: CMTimeRange) {
    if CMTimeCompare(range.duration, .zero) <= 0 { return }
    instructions.append(
      ExportCompositionInstruction(
        timeRange: range,
        outgoingTrackID: videoTracks[0].trackID,
        incomingTrackID: kCMPersistentTrackID_Invalid,
        effect: "",
        kind: "",
        reverse: false,
        layers: [],
        preferredTransform: baseTransform,
        incomingScaleFrom: 0.84,
        incomingScaleTo: 1
      )
    )
  }
  var covered = CMTime.zero
  for (index, placement) in placements.enumerated() {
    if CMTimeCompare(placement.start, covered) > 0 {
      passthrough(CMTimeRange(start: covered, end: placement.start))
    }
    let tdMs = max(0, placement.transitionMs)
    let td = cmTimeMs(tdMs)
    let hasTransition = tdMs > 0 && index < placements.count - 1
    // Placement includes ±td/2 handles; solo excludes the full centered blend.
    let incomingMs = index > 0 ? placements[index - 1].transitionMs : 0
    let soloStart = CMTimeAdd(placement.start, cmTimeMs(incomingMs))
    let soloEnd = hasTransition
      ? CMTimeSubtract(placement.end, td)
      : placement.end
    if CMTimeCompare(soloEnd, soloStart) > 0 {
      instructions.append(
        ExportCompositionInstruction(
          timeRange: CMTimeRange(start: soloStart, end: soloEnd),
          outgoingTrackID: videoTracks[placement.trackIndex].trackID,
          incomingTrackID: kCMPersistentTrackID_Invalid,
          effect: "",
          kind: "",
          reverse: false,
          layers: [],
          preferredTransform: baseTransform,
          incomingScaleFrom: 0.84,
          incomingScaleTo: 1
        )
      )
    }
    if hasTransition {
      let next = placements[index + 1]
      instructions.append(
        ExportCompositionInstruction(
          timeRange: CMTimeRange(start: soloEnd, duration: td),
          outgoingTrackID: videoTracks[placement.trackIndex].trackID,
          incomingTrackID: videoTracks[next.trackIndex].trackID,
          effect: placement.effect,
          kind: placement.kind,
          reverse: placement.reverse,
          layers: placement.motion,
          preferredTransform: baseTransform,
          incomingScaleFrom: placement.incomingScaleFrom,
          incomingScaleTo: placement.incomingScaleTo,
          wipeEdge: placement.wipeEdge
        )
      )
    }
    covered = placement.end
  }
  return instructions
}

final class ExportCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
  let timeRange: CMTimeRange
  let enablePostProcessing = true
  let containsTweening = true
  let requiredSourceTrackIDs: [NSValue]?
  let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
  let outgoingTrackID: CMPersistentTrackID
  let incomingTrackID: CMPersistentTrackID
  let effect: String
  let kind: String
  let reverse: Bool
  let layers: [ExportMotion]
  let preferredTransform: CGAffineTransform
  let incomingScaleFrom: CGFloat
  let incomingScaleTo: CGFloat
  let wipeEdge: String

  init(
    timeRange: CMTimeRange,
    outgoingTrackID: CMPersistentTrackID,
    incomingTrackID: CMPersistentTrackID,
    effect: String,
    kind: String,
    reverse: Bool,
    layers: [ExportMotion],
    preferredTransform: CGAffineTransform,
    incomingScaleFrom: CGFloat,
    incomingScaleTo: CGFloat,
    wipeEdge: String = ""
  ) {
    self.timeRange = timeRange
    self.outgoingTrackID = outgoingTrackID
    self.incomingTrackID = incomingTrackID
    self.effect = effect
    self.kind = kind
    self.reverse = reverse
    self.layers = layers
    self.preferredTransform = preferredTransform
    self.incomingScaleFrom = incomingScaleFrom
    self.incomingScaleTo = incomingScaleTo
    self.wipeEdge = wipeEdge
    if incomingTrackID == kCMPersistentTrackID_Invalid {
      requiredSourceTrackIDs = [NSNumber(value: outgoingTrackID)]
    } else {
      requiredSourceTrackIDs = [
        NSNumber(value: outgoingTrackID),
        NSNumber(value: incomingTrackID),
      ]
    }
    super.init()
  }
}

final class ExportFrameCompositor: NSObject, AVVideoCompositing {
  private let renderer = ExportFrameRenderer()
  private let queue = DispatchQueue(label: "aveditor.export.frames")
  var sourcePixelBufferAttributes: [String: Any]? = [
    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
  ]
  var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
  ]

  func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

  func cancelAllPendingVideoCompositionRequests() {}

  func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
    guard let instruction = request.videoCompositionInstruction as? ExportCompositionInstruction,
          let dst = request.renderContext.newPixelBuffer()
    else {
      request.finish(with: NSError(domain: "ExportFrameCompositor", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Missing composition instruction",
      ]))
      return
    }
    // Sample buffers must be taken before startRequest returns.
    let outBuf = request.sourceFrame(byTrackID: instruction.outgoingTrackID)
    let incoming = instruction.incomingTrackID == kCMPersistentTrackID_Invalid
      ? nil
      : request.sourceFrame(byTrackID: instruction.incomingTrackID)
    let duration = CMTimeGetSeconds(instruction.timeRange.duration)
    let elapsed = CMTimeGetSeconds(request.compositionTime) - CMTimeGetSeconds(instruction.timeRange.start)
    let t = duration > 0.0001 ? CGFloat(min(1, max(0, elapsed / duration))) : 1
    let compositionSeconds = CMTimeGetSeconds(request.compositionTime)
    queue.async { [renderer] in
      if outBuf == nil && incoming == nil {
        renderer.renderBlack(into: dst)
      } else {
        renderer.render(
          outgoing: outBuf,
          incoming: incoming,
          destination: dst,
          progress: t,
          compositionSeconds: compositionSeconds,
          instruction: instruction
        )
      }
      request.finish(withComposedVideoFrame: dst)
    }
  }
}

private struct ExportPose {
  var opacity: CGFloat = 1
  var scale: CGFloat = 1
  var turns: CGFloat = 0
  var tx: CGFloat = 0
  var ty: CGFloat = 0
  var blur: CGFloat = 0
  var brightness: CGFloat = 0
  /// `"zoom"` → radial zoom blur (server `mode`); otherwise gaussian.
  var blurMode: String = ""
  /// 0 = full, 1 = fully wiped away.
  var wipe: CGFloat = 0
  /// Edge erased first: left | right | top | bottom.
  var wipeEdge: String = "left"
}

private final class ExportFrameRenderer {
  private let context: CIContext
  private let lock = NSLock()

  init() {
    let device = MTLCreateSystemDefaultDevice()
    if let device {
      context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    } else {
      context = CIContext(options: [.useSoftwareRenderer: true])
    }
  }

  func renderBlack(into destination: CVPixelBuffer) {
    let w = CGFloat(CVPixelBufferGetWidth(destination))
    let h = CGFloat(CVPixelBufferGetHeight(destination))
    let canvas = CGRect(x: 0, y: 0, width: w, height: h)
    lock.lock()
    context.render(
      CIImage(color: .black).cropped(to: canvas),
      to: destination,
      bounds: canvas,
      colorSpace: CGColorSpaceCreateDeviceRGB()
    )
    lock.unlock()
  }

  func render(
    outgoing: CVPixelBuffer?,
    incoming: CVPixelBuffer?,
    destination: CVPixelBuffer,
    progress t: CGFloat,
    compositionSeconds: Double,
    instruction: ExportCompositionInstruction
  ) {
    let w = CGFloat(CVPixelBufferGetWidth(destination))
    let h = CGFloat(CVPixelBufferGetHeight(destination))
    let canvas = CGRect(x: 0, y: 0, width: w, height: h)
    let outImage = outgoing.map { placed($0, instruction.preferredTransform, canvas) }
    let inImage = incoming.map { placed($0, instruction.preferredTransform, canvas) }
    var composed: CIImage
    if let outImage, let inImage {
      composed = compose(outImage: outImage, inImage: inImage, t: t, instruction: instruction, canvas: canvas)
    } else {
      composed = outImage ?? inImage ?? CIImage(color: .black).cropped(to: canvas)
    }
    composed = applyOverlays(composed, seconds: compositionSeconds, canvas: canvas)
    lock.lock()
    context.render(composed, to: destination, bounds: canvas, colorSpace: CGColorSpaceCreateDeviceRGB())
    lock.unlock()
  }

  private func compose(
    outImage: CIImage,
    inImage: CIImage,
    t: CGFloat,
    instruction: ExportCompositionInstruction,
    canvas: CGRect
  ) -> CIImage {
    if instruction.kind == "doorway" {
      return composeDoorway(
        outImage,
        inImage,
        t: t,
        scaleFrom: instruction.incomingScaleFrom,
        scaleTo: instruction.incomingScaleTo,
        canvas: canvas
      )
    }
    if instruction.kind == "puzzle" {
      return composePuzzle(outImage, inImage, t: t, reverse: instruction.reverse, canvas: canvas)
    }
    if instruction.kind == "wipe" {
      return composeWipe(outImage, inImage, t: t, edge: instruction.wipeEdge, canvas: canvas)
    }
    if !instruction.layers.isEmpty {
      return composeLayers(outImage, inImage, layers: instruction.layers, t: t, canvas: canvas)
    }
    return composeNamed(outImage, inImage, effect: instruction.effect, t: t, canvas: canvas)
  }

  private func composeLayers(
    _ outgoing: CIImage,
    _ incoming: CIImage,
    layers: [ExportMotion],
    t: CGFloat,
    canvas: CGRect
  ) -> CIImage {
    let (outPose, inPose, outgoingOnTop) = evaluateExportPoses(layers, t: t)
    let outLayer = applyPose(outgoing, outPose, canvas: canvas)
    let inLayer = applyPose(incoming, inPose, canvas: canvas)
    let bottom = outgoingOnTop ? inLayer : outLayer
    let top = outgoingOnTop ? outLayer : inLayer
    var image = top.composited(over: bottom.composited(over: CIImage(color: .black).cropped(to: canvas)))
    let veil = sharedVeil(outPose, inPose)
    if veil > 0.001 {
      let color: CIColor = outPose.brightness >= 0 ? CIColor(red: 1, green: 1, blue: 1, alpha: veil) : CIColor(red: 0, green: 0, blue: 0, alpha: veil)
      image = CIImage(color: color).cropped(to: canvas).composited(over: image)
    }
    return image.cropped(to: canvas)
  }

  private func composeWipe(
    _ outgoing: CIImage,
    _ incoming: CIImage,
    t: CGFloat,
    edge: String,
    canvas: CGRect
  ) -> CIImage {
    let w = canvas.width
    let h = canvas.height
    let resolved: String
    switch edge {
    case "right", "top", "bottom", "left":
      resolved = edge
    default:
      // Legacy name bridge when edge omitted.
      resolved = "left"
    }
    return wipe(incoming, over: outgoing, t: t, canvas: canvas) {
      switch resolved {
      case "right":
        return CGRect(x: w * (1 - t), y: 0, width: w * t, height: h)
      case "top":
        return CGRect(x: 0, y: h * (1 - t), width: w, height: h * t)
      case "bottom":
        return CGRect(x: 0, y: 0, width: w, height: h * t)
      default: // left
        return CGRect(x: 0, y: 0, width: w * t, height: h)
      }
    }
  }

  private func composeNamed(
    _ outgoing: CIImage,
    _ incoming: CIImage,
    effect: String,
    t: CGFloat,
    canvas: CGRect
  ) -> CIImage {
    let w = canvas.width
    let h = canvas.height
    switch effect {
    case "wipeleft":
      return wipe(incoming, over: outgoing, t: t, canvas: canvas) {
        CGRect(x: w * (1 - t), y: 0, width: w * t, height: h)
      }
    case "wiperight":
      return wipe(incoming, over: outgoing, t: t, canvas: canvas) {
        CGRect(x: 0, y: 0, width: w * t, height: h)
      }
    case "wipeup":
      return wipe(incoming, over: outgoing, t: t, canvas: canvas) {
        CGRect(x: 0, y: h * (1 - t), width: w, height: h * t)
      }
    case "wipedown":
      return wipe(incoming, over: outgoing, t: t, canvas: canvas) {
        CGRect(x: 0, y: 0, width: w, height: h * t)
      }
    case "circleclose":
      return circleMask(foreground: outgoing, background: incoming, radiusFactor: 1 - t, canvas: canvas)
    case "circleopen", "radial":
      return circleMask(foreground: incoming, background: outgoing, radiusFactor: t, canvas: canvas)
    case "slideleft", "pushleft":
      return translated(outgoing, dx: -w * t, dy: 0, canvas: canvas)
        .composited(over: CIImage(color: .black).cropped(to: canvas))
        .applying(incoming, dx: w * (1 - t), dy: 0, canvas: canvas)
    case "slideright", "pushright":
      return translated(outgoing, dx: w * t, dy: 0, canvas: canvas)
        .applying(incoming, dx: -w * (1 - t), dy: 0, canvas: canvas)
    case "slideup", "pushup":
      return translated(outgoing, dx: 0, dy: h * t, canvas: canvas)
        .applying(incoming, dx: 0, dy: -h * (1 - t), canvas: canvas)
    case "slidedown", "pushdown":
      return translated(outgoing, dx: 0, dy: -h * t, canvas: canvas)
        .applying(incoming, dx: 0, dy: h * (1 - t), canvas: canvas)
    case "fadeblack":
      return dip(outgoing, incoming, t: t, white: false, canvas: canvas)
    case "fadewhite":
      return dip(outgoing, incoming, t: t, white: true, canvas: canvas)
    default:
      return applyPose(incoming, ExportPose(opacity: t), canvas: canvas)
        .composited(over: applyPose(outgoing, ExportPose(opacity: 1 - t), canvas: canvas))
    }
  }

  private func composeDoorway(
    _ outgoing: CIImage,
    _ incoming: CIImage,
    t: CGFloat,
    scaleFrom: CGFloat,
    scaleTo: CGFloat,
    canvas: CGRect
  ) -> CIImage {
    let u = exportEase(t, "easeInOut")
    let door = canvas.width * 0.5 * (1 - u)
    let bScale = scaleFrom + (scaleTo - scaleFrom) * exportEase(u, "easeOut")
    let incomingPosed = applyPose(incoming, ExportPose(scale: bScale), canvas: canvas)
    if door < 0.5 {
      return incomingPosed.cropped(to: canvas)
    }
    let left = outgoing.cropped(to: CGRect(x: 0, y: 0, width: door, height: canvas.height))
    let right = outgoing.cropped(to: CGRect(x: canvas.width - door, y: 0, width: door, height: canvas.height))
    return right.composited(over: left.composited(over: incomingPosed.composited(over: CIImage(color: .black).cropped(to: canvas))))
  }

  private func composePuzzle(
    _ outgoing: CIImage,
    _ incoming: CIImage,
    t: CGFloat,
    reverse: Bool,
    canvas: CGRect
  ) -> CIImage {
    let strip = canvas.width / 3
    let columns: [CGFloat] = reverse ? [0, 1, 2] : [2, 1, 0]
    var image = outgoing
    for phase in 0..<3 {
      let local = min(1, max(0, (t - CGFloat(phase) / 3) * 3))
      if local <= 0 { continue }
      let eased = exportEase(local, "easeOut")
      let col = columns[phase]
      let dx: CGFloat
      let dy: CGFloat
      if col == 1 {
        dx = 0
        dy = (reverse ? 1 : -1) * canvas.height * (1 - eased)
      } else {
        dx = (reverse ? 1 : -1) * strip * (1 - eased)
        dy = 0
      }
      let crop = CGRect(x: col * strip, y: 0, width: strip, height: canvas.height)
      let piece = incoming
        .transformed(by: CGAffineTransform(translationX: dx, y: -dy))
        .cropped(to: crop)
      image = piece.composited(over: image)
    }
    return image.cropped(to: canvas)
  }

  private func circleMask(
    foreground: CIImage,
    background: CIImage,
    radiusFactor: CGFloat,
    canvas: CGRect
  ) -> CIImage {
    let radius = hypot(canvas.width, canvas.height) * 0.5 * max(0, radiusFactor)
    if radius < 0.5 { return background.cropped(to: canvas) }
    if radius >= hypot(canvas.width, canvas.height) * 0.5 {
      return foreground.cropped(to: canvas)
    }
    guard let gradient = CIFilter(name: "CIRadialGradient"),
          let blend = CIFilter(name: "CIBlendWithMask")
    else {
      return background
    }
    gradient.setValue(CIVector(x: canvas.midX, y: canvas.midY), forKey: "inputCenter")
    gradient.setValue(radius, forKey: "inputRadius0")
    gradient.setValue(radius + 1.5, forKey: "inputRadius1")
    gradient.setValue(CIColor.white, forKey: "inputColor0")
    gradient.setValue(CIColor.black, forKey: "inputColor1")
    guard let mask = gradient.outputImage?.cropped(to: canvas) else {
      return background
    }
    blend.setValue(foreground, forKey: kCIInputImageKey)
    blend.setValue(background, forKey: kCIInputBackgroundImageKey)
    blend.setValue(mask, forKey: kCIInputMaskImageKey)
    return (blend.outputImage ?? background).cropped(to: canvas)
  }

  private func wipe(
    _ incoming: CIImage,
    over outgoing: CIImage,
    t: CGFloat,
    canvas: CGRect,
    rect: () -> CGRect
  ) -> CIImage {
    if t <= 0.001 { return outgoing.cropped(to: canvas) }
    if t >= 0.999 { return incoming.cropped(to: canvas) }
    let crop = rect()
    if crop.width < 0.5 || crop.height < 0.5 { return outgoing.cropped(to: canvas) }
    return incoming.cropped(to: crop).composited(over: outgoing).cropped(to: canvas)
  }

  private func dip(_ outgoing: CIImage, _ incoming: CIImage, t: CGFloat, white: Bool, canvas: CGRect) -> CIImage {
    let amount = t < 0.5 ? t * 2 : (1 - t) * 2
    let base = t < 0.5 ? outgoing : incoming
    let color = white
      ? CIColor(red: 1, green: 1, blue: 1, alpha: amount)
      : CIColor(red: 0, green: 0, blue: 0, alpha: amount)
    return CIImage(color: color).cropped(to: canvas).composited(over: base)
  }

  private func translated(_ image: CIImage, dx: CGFloat, dy: CGFloat, canvas: CGRect) -> CIImage {
    image.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: canvas)
  }

  private func applying(_ background: CIImage, _ image: CIImage, dx: CGFloat, dy: CGFloat, canvas: CGRect) -> CIImage {
    translated(image, dx: dx, dy: dy, canvas: canvas).composited(over: background)
  }

  private func placed(_ buffer: CVPixelBuffer, _ transform: CGAffineTransform, _ canvas: CGRect) -> CIImage {
    CIImage(cvPixelBuffer: buffer).transformed(by: transform).cropped(to: canvas)
  }

  private func applyOverlays(_ image: CIImage, seconds: Double, canvas: CGRect) -> CIImage {
    let overlays = ExportOverlayStore.current()
    if overlays.isEmpty { return image }
    var result = image
    let ms = Int(seconds * 1000)
    for overlay in overlays {
      guard overlayVisible(overlay, atMs: ms),
            let ci = overlayImage(overlay, canvas: canvas)
      else { continue }
      result = ci.composited(over: result)
    }
    return result.cropped(to: canvas)
  }

  private func overlayVisible(_ overlay: [String: Any], atMs ms: Int) -> Bool {
    guard let spans = overlay["spans"] as? [[String: Any]], !spans.isEmpty else { return true }
    return spans.contains { span in
      let start = span["startMs"] as? Int ?? 0
      let end = span["endMs"] as? Int ?? 0
      return ms >= start && ms < end
    }
  }

  private func overlayImage(_ overlay: [String: Any], canvas: CGRect) -> CIImage? {
    let path: String?
    if let file = overlay["path"] as? String {
      path = file
    } else if let dir = overlay["sequenceDir"] as? String,
              let count = overlay["frameCount"] as? Int,
              count > 0 {
      path = String(format: "%@/frame_%04d.png", dir, count)
    } else {
      path = nil
    }
    guard let path, let ui = UIImage(contentsOfFile: path), let cg = ui.cgImage else { return nil }
    var ci = CIImage(cgImage: cg)
    ci = ci.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -ci.extent.height))
    let e = ci.extent
    let sx = canvas.width / max(e.width, 1)
    let sy = canvas.height / max(e.height, 1)
    return ci
      .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
      .transformed(by: CGAffineTransform(translationX: -e.origin.x * sx, y: -e.origin.y * sy))
      .cropped(to: canvas)
  }
}

private extension CIImage {
  func applying(_ image: CIImage, dx: CGFloat, dy: CGFloat, canvas: CGRect) -> CIImage {
    image.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: canvas).composited(over: self)
  }
}

private func evaluateExportPoses(_ layers: [ExportMotion], t: CGFloat) -> (ExportPose, ExportPose, Bool) {
  var outgoing = ExportPose()
  var incoming = ExportPose(opacity: 0)
  let hasOpacity = layers.contains { $0.property == "opacity" }
  if !hasOpacity {
    // Match preview: rotation/slide/wipe stay solid. Scale-only still crossfades.
    let spatial = layers.contains {
      ["translateX", "translateY", "rotation", "wipe"].contains($0.property)
    }
    if spatial {
      outgoing.opacity = 1
      incoming.opacity = 1
    } else {
      outgoing.opacity = 1 - t
      incoming.opacity = t
    }
  }
  var outgoingOpacity = false
  var incomingOpacity = false
  for layer in layers where t >= layer.start {
    let span = max(layer.end - layer.start, 0.0001)
    let local = min(1, (t - layer.start) / span)
    let value = layer.from + (layer.to - layer.from) * exportEase(local, layer.easing)
    func apply(_ pose: inout ExportPose, opacity: inout Bool) {
      switch layer.property {
      case "opacity":
        pose.opacity = min(1, max(0, value))
        opacity = true
      case "scale": pose.scale = value
      case "rotation": pose.turns = value
      case "translateX": pose.tx = value
      case "translateY": pose.ty = value
      case "blur":
        pose.blur = value
        if !layer.mode.isEmpty { pose.blurMode = layer.mode }
      case "brightness": pose.brightness = value
      case "wipe":
        pose.wipe = min(1, max(0, value))
        if !layer.mode.isEmpty { pose.wipeEdge = layer.mode }
      default: break
      }
    }
    if layer.target == "A" || layer.target == "both" {
      apply(&outgoing, opacity: &outgoingOpacity)
    }
    if layer.target == "B" || layer.target == "both" {
      apply(&incoming, opacity: &incomingOpacity)
    }
  }
  if hasOpacity {
    if outgoingOpacity && !incomingOpacity { incoming.opacity = 1 - outgoing.opacity }
    if incomingOpacity && !outgoingOpacity { outgoing.opacity = 1 - incoming.opacity }
  }
  return (outgoing, incoming, exportAOnTop(layers))
}

/// Last layer with target A or B paints on top (`both` ignored).
private func exportAOnTop(_ layers: [ExportMotion]) -> Bool {
  var top: String?
  for layer in layers {
    if layer.target == "A" || layer.target == "B" {
      top = layer.target
    }
  }
  return top == "A"
}

private func clearCanvas(_ canvas: CGRect) -> CIImage {
  CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: canvas)
}

private func applyPose(_ image: CIImage, _ pose: ExportPose, canvas: CGRect) -> CIImage {
  if pose.opacity <= 0.001 || abs(pose.scale) < 0.001 || pose.wipe >= 0.999 {
    return clearCanvas(canvas)
  }
  var img = image
  if pose.blur.magnitude > 0.3 {
    if pose.blurMode == "zoom", let zoom = CIFilter(name: "CIZoomBlur") {
      // Server blur units → CIZoomBlur amount (light-streak / radial look).
      zoom.setValue(img, forKey: kCIInputImageKey)
      zoom.setValue(
        CIVector(x: canvas.midX, y: canvas.midY),
        forKey: kCIInputCenterKey
      )
      zoom.setValue(pose.blur.magnitude * 2.4, forKey: kCIInputAmountKey)
      img = (zoom.outputImage ?? img).cropped(to: canvas)
    } else if let blur = CIFilter(name: "CIGaussianBlur") {
      blur.setValue(img, forKey: kCIInputImageKey)
      blur.setValue(pose.blur.magnitude, forKey: kCIInputRadiusKey)
      img = (blur.outputImage ?? img).cropped(to: canvas)
    }
  }
  let cx = canvas.midX
  let cy = canvas.midY
  // Scale/rotate around center, then translate in canvas space (Flutter order).
  img = img
    .transformed(by: CGAffineTransform(translationX: -cx, y: -cy))
    .transformed(by: CGAffineTransform(scaleX: pose.scale, y: pose.scale))
    .transformed(by: CGAffineTransform(rotationAngle: pose.turns * 2 * .pi))
    .transformed(by: CGAffineTransform(
      translationX: cx + canvas.width * pose.tx,
      y: cy - canvas.height * pose.ty
    ))
    .cropped(to: canvas)
  if pose.wipe > 0.001 {
    let w = canvas.width
    let h = canvas.height
    let u = min(1, max(0, pose.wipe))
    let remain = 1 - u
    let crop: CGRect
    switch pose.wipeEdge {
    case "right":
      crop = CGRect(x: canvas.minX, y: canvas.minY, width: w * remain, height: h)
    case "top":
      crop = CGRect(x: canvas.minX, y: canvas.minY, width: w, height: h * remain)
    case "bottom":
      crop = CGRect(x: canvas.minX, y: canvas.minY + h * u, width: w, height: h * remain)
    default: // left
      crop = CGRect(x: canvas.minX + w * u, y: canvas.minY, width: w * remain, height: h)
    }
    let kept = crop.intersection(canvas)
    if kept.isNull || kept.isEmpty {
      return clearCanvas(canvas)
    }
    img = img.cropped(to: kept).composited(over: clearCanvas(canvas)).cropped(to: canvas)
  }
  if pose.opacity < 0.999, let matrix = CIFilter(name: "CIColorMatrix") {
    matrix.setValue(img, forKey: kCIInputImageKey)
    matrix.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
    matrix.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
    matrix.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
    matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: pose.opacity), forKey: "inputAVector")
    matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
    img = (matrix.outputImage ?? img).cropped(to: canvas)
  }
  return img
}

private func sharedVeil(_ a: ExportPose, _ b: ExportPose) -> CGFloat {
  if a.brightness.magnitude < 0.001 && b.brightness.magnitude < 0.001 { return 0 }
  if (a.brightness - b.brightness).magnitude < 0.02 && a.brightness.sign == b.brightness.sign {
    return min(1, a.brightness.magnitude)
  }
  return 0
}

private func orient(_ image: CIImage, _ transform: CGAffineTransform) -> CIImage {
  let img = image.transformed(by: transform)
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
