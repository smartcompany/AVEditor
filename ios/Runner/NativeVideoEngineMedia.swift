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
  let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
  let compAudio = request.hasVideoAudio
    ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    : nil
  let sourceAudio = source.tracks(withMediaType: .audio).first

  var cursor = CMTime.zero
  for (index, segment) in request.segments.enumerated() {
    let startMs = segment["startMs"] as? Int ?? 0
    let endMs = segment["endMs"] as? Int ?? 0
    let range = CMTimeRange(
      start: CMTime(value: CMTimeValue(startMs), timescale: 1000),
      duration: CMTime(value: CMTimeValue(max(0, endMs - startMs)), timescale: 1000)
    )
    try compVideo.insertTimeRange(range, of: sourceVideo, at: cursor)
    if let compAudio, let sourceAudio {
      try? compAudio.insertTimeRange(range, of: sourceAudio, at: cursor)
    }

    // Overlap next segment for transition duration (xfade-style).
    let tdMs = segment["transitionDurationMs"] as? Int ?? 0
    if tdMs > 0, index < request.segments.count - 1 {
      cursor = CMTimeAdd(cursor, CMTimeSubtract(range.duration, CMTime(value: CMTimeValue(tdMs), timescale: 1000)))
    } else {
      cursor = CMTimeAdd(cursor, range.duration)
    }
  }

  // Music tracks.
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
  let videoComp = AVMutableVideoComposition()
  videoComp.renderSize = renderSize
  videoComp.frameDuration = CMTime(value: 1, timescale: 30)

  let instruction = AVMutableVideoCompositionInstruction()
  instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
  let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)

  // Cover-scale + center crop into renderSize, then optional rotation.
  let natural = sourceVideo.naturalSize.applying(sourceVideo.preferredTransform)
  let srcW = abs(natural.width)
  let srcH = abs(natural.height)
  let scale = max(renderSize.width / max(srcW, 1), renderSize.height / max(srcH, 1))
  var transform = sourceVideo.preferredTransform
  transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
  let scaledW = srcW * scale
  let scaledH = srcH * scale
  transform = transform.concatenating(
    CGAffineTransform(translationX: (renderSize.width - scaledW) / 2, y: (renderSize.height - scaledH) / 2)
  )
  if request.rotationDegrees != 0 {
    let radians = CGFloat(request.rotationDegrees)
    transform = transform.concatenating(
      CGAffineTransform(translationX: renderSize.width / 2, y: renderSize.height / 2)
        .rotated(by: radians)
        .translatedBy(x: -renderSize.width / 2, y: -renderSize.height / 2)
    )
  }
  layer.setTransform(transform, at: .zero)
  instruction.layerInstructions = [layer]
  videoComp.instructions = [instruction]

  // Overlay PNGs via Core Animation post-process.
  if !request.overlays.isEmpty {
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
        // Hold last entrance frame for the span (CapCut-like settle).
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
  if request.durationMs > 0 {
    session.timeRange = CMTimeRange(
      start: .zero,
      duration: CMTime(value: CMTimeValue(request.durationMs), timescale: 1000)
    )
  }

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
      completion(.failure(session.error ?? NSError(domain: "NativeVideoEngine", code: 25)))
    }
  }
}
