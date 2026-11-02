import AVFoundation
import CoreImage

/// A small decoded frame for the frame strip and the change search.
struct Thumbnail {
    /// The frame start in mpv playback time.
    let time: Double
    let image: CGImage
    /// A tiny grayscale copy of the frame. It finds frames that differ from the frame before.
    let signature: [UInt8]

    /// True when the two frames look different. Compression noise does not count.
    func differs(from other: Thumbnail) -> Bool {
        guard signature.count == other.signature.count else { return true }
        return zip(signature, other.signature).contains { abs(Int($0) - Int($1)) > 12 }
    }
}

/// Decodes runs of consecutive frames in the background.
///
/// When a frame index exists (MP4 and MOV), AVFoundation decodes the frames in order.
/// For other files, a hidden mpv instance steps from frame to frame.
final class FrameReader {
    private let url: URL
    private let index: FrameIndex?
    private let asset: AVURLAsset
    private let video: Task<VideoTrack?, Never>

    init(url: URL, index: FrameIndex?) {
        self.url = url
        self.index = index
        let asset = AVURLAsset(url: url)
        self.asset = asset
        video = Task { await VideoTrack.load(asset) }
    }

    /// Up to `count` frames, from the frame shown at `time` forward, scaled to fit in `size` pixels.
    /// The stream ends early at the end of the file. Cancel the task that reads it to stop decoding.
    func frames(from time: Double, count: Int, fitting size: CGSize) -> AsyncThrowingStream<Thumbnail, Error> {
        if let index {
            return assetFrames(index, from: time, count: count, fitting: size)
        }
        return mpvFrames(from: time, count: count, fitting: size)
    }

    private func assetFrames(_ index: FrameIndex, from time: Double, count: Int,
                             fitting size: CGSize) -> AsyncThrowingStream<Thumbnail, Error> {
        let first = index.frame(at: time)
        let last = min(first + count, index.count) - 1
        let asset = asset, video = video
        return AsyncThrowingStream { continuation in
            let stop = StopFlag()
            let task = Task {
                guard first <= last, let track = await video.value else { return continuation.finish() }
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try Self.decode(asset, track, index, frames: first...last, fitting: size, stop: stop) {
                            continuation.yield($0)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in
                stop.set()
                task.cancel()
            }
        }
    }

    /// Decodes the frames in order with one pass from the keyframe before them.
    /// A request per frame (AVAssetImageGenerator) decodes from the keyframe again for each frame,
    /// and that is about ten times slower in files with keyframes far apart.
    private static func decode(_ asset: AVAsset, _ video: VideoTrack, _ index: FrameIndex, frames: ClosedRange<Int>,
                               fitting size: CGSize, stop: StopFlag, yield: (Thumbnail) -> Void) throws {
        // The decoder scales before the rotation, so a quarter turn swaps the width and the height.
        let shown = video.isQuarterTurn ? CGSize(width: video.size.height, height: video.size.width) : video.size
        let scale = min(1, size.width / shown.width, size.height / shown.height)
        let width = max(2, Int(video.size.width * scale)), height = max(2, Int(video.size.height * scale))

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video.track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        // The reader can return an extra sample at the start of the range that shows the frame before.
        // Start one frame early, so that sample and the frame before are both skipped.
        let start = index.times[max(frames.lowerBound - 1, 0)] + index.assetOffset
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 1_000_000),
            end: CMTime(seconds: index.times[frames.upperBound] + index.assetOffset + 0.0005, preferredTimescale: 1_000_000))
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        defer { reader.cancelReading() }

        while !stop.isSet, let sample = output.copyNextSampleBuffer() {
            let frame = index.frame(at: CMSampleBufferGetPresentationTimeStamp(sample).seconds - index.assetOffset)
            guard frames.contains(frame), let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let image = CIImage(cvPixelBuffer: buffer).oriented(video.orientation)
            guard let cgImage = context.createCGImage(image, from: image.extent) else { continue }
            yield(Thumbnail(time: index.times[frame], image: cgImage, signature: signature(of: cgImage)))
            if frame == frames.upperBound { break }
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    private func mpvFrames(from time: Double, count: Int, fitting size: CGSize) -> AsyncThrowingStream<Thumbnail, Error> {
        let url = url
        return AsyncThrowingStream { continuation in
            let stop = StopFlag()
            continuation.onTermination = { _ in stop.set() }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let session = try MPVSession(source: url, start: time)
                    defer { session.close() }
                    for number in 0..<count where !stop.isSet {
                        guard let position = session.position, let frame = session.screenshot(),
                              let image = Self.scale(frame, fitting: size) else { break }
                        continuation.yield(Thumbnail(time: position, image: image, signature: Self.signature(of: image)))
                        if number == count - 1 || !session.stepForward(from: position) { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private static func scale(_ image: CGImage, fitting size: CGSize) -> CGImage? {
        let scale = min(1, size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let width = max(1, Int(CGFloat(image.width) * scale)), height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// A 96-pixel-wide grayscale copy. At this size, one pixel averages a block of about 20 × 20
    /// pixels of a 1080p frame. A moved cursor or a blinking caret changes it, and encoder noise does not.
    private static func signature(of image: CGImage) -> [UInt8] {
        let width = 96
        let height = max(1, min(96, Int((Double(width) * Double(image.height) / Double(image.width)).rounded())))
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }
}

/// The video track and how to turn its frames upright.
private struct VideoTrack: @unchecked Sendable {
    let track: AVAssetTrack
    let size: CGSize
    let orientation: CGImagePropertyOrientation

    var isQuarterTurn: Bool { [.left, .right, .leftMirrored, .rightMirrored].contains(orientation) }

    static func load(_ asset: AVAsset) async -> VideoTrack? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        return VideoTrack(track: track, size: size, orientation: orientation(of: transform))
    }

    /// Phones store portrait video as landscape frames with a rotation in the track transform.
    private static func orientation(of t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (t.a, t.b, t.c, t.d) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        default: return .up
        }
    }
}

/// Tells the decoding thread that the reader stopped listening.
private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
