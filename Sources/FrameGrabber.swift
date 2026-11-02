import Foundation
import ImageIO
import Libmpv
import UniformTypeIdentifiers

/// Saves the frames around a time as PNG files.
///
/// A hidden mpv instance does the work, so the visible player keeps its position.
/// mpv steps frame by frame, so the result is exact for variable frame rate files too.
/// This blocks. Call it off the main thread.
enum FrameGrabber {
    struct Frame {
        let url: URL
        let time: Double
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// - Parameter fileName: Gets the frame time and returns a file name for it.
    static func grab(_ source: URL, at time: Double, before: Int, after: Int,
                     into folder: URL, fileName: (Double) -> String) throws -> [Frame] {
        let session = try Session(source: source, start: time)
        defer { session.close() }
        // The frame mpv shows for `time`. Count "after" frames from this one.
        guard let anchor = session.position else { throw Failure(errorDescription: "mpv has no position.") }

        // Step back to the first frame. Stop early at the start of the file.
        for _ in 0..<before {
            let previous = session.position
            session.command("frame-back-step")
            guard session.waitForEvent(MPV_EVENT_PLAYBACK_RESTART, timeout: 10) else { break }
            if let previous, let now = session.position, now >= previous { break }
        }

        var frames: [Frame] = []
        while true {
            guard let position = session.position else { break }
            let url = folder.appendingPathComponent(fileName(position))
            guard let image = session.screenshot(), writePNG(image, to: url) else {
                throw Failure(errorDescription: "mpv could not save the frame at \(position) seconds.")
            }
            frames.append(Frame(url: url, time: position))

            // Stop after `after` frames past the paused frame.
            let pastPause = frames.filter { $0.time > anchor }.count
            if pastPause >= after { break }

            session.command("frame-step")
            let advanced = { session.position.map { $0 > position } ?? false }
            _ = session.waitUntil(timeout: 3) { advanced() || session.isAtEnd }
            guard advanced() else { break }
        }
        return frames
    }

    /// ImageIO writes the PNG. The FFmpeg build in MPVKit has no PNG encoder.
    private static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}

/// A hidden, paused mpv instance with no video or audio output.
private final class Session {
    private let handle: OpaquePointer

    init(source: URL, start: Double) throws {
        guard let handle = mpv_create() else { throw FrameGrabber.Failure(errorDescription: "mpv_create failed.") }
        self.handle = handle
        for (name, value) in [
            ("vo", "null"), ("ao", "null"), ("aid", "no"), ("sid", "no"),
            ("pause", "yes"), ("hr-seek", "yes"), ("keep-open", "always"),
            ("hwdec", "no"), ("start", String(start)),
        ] {
            mpv_set_option_string(handle, name, value)
        }
        guard mpv_initialize(handle) >= 0 else {
            mpv_terminate_destroy(handle)
            throw FrameGrabber.Failure(errorDescription: "mpv_initialize failed.")
        }
        command("loadfile", source.isFileURL ? source.path : source.absoluteString)
        guard waitForEvent(MPV_EVENT_PLAYBACK_RESTART, timeout: 15) else {
            close()
            throw FrameGrabber.Failure(errorDescription: "mpv could not open the video.")
        }
    }

    func close() {
        mpv_terminate_destroy(handle)
    }

    var position: Double? {
        var value = 0.0
        return mpv_get_property(handle, "time-pos", MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
    }

    var isAtEnd: Bool {
        var value: Int32 = 0
        return mpv_get_property(handle, "eof-reached", MPV_FORMAT_FLAG, &value) >= 0 && value != 0
    }

    @discardableResult
    func command(_ args: String...) -> Int32 {
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
        defer { cargs.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        return mpv_command(handle, &cargs)
    }

    /// The current video frame, without subtitles. mpv returns it as "bgr0" pixels.
    func screenshot() -> CGImage? {
        let args: [String] = ["screenshot-raw", "video", "bgr0"]
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
        defer { cargs.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        var result = mpv_node()
        guard mpv_command_ret(handle, &cargs, &result) >= 0 else { return nil }
        defer { mpv_free_node_contents(&result) }
        guard result.format == MPV_FORMAT_NODE_MAP, let list = result.u.list?.pointee else { return nil }

        var width = 0, height = 0, stride = 0
        var pixels: Data?
        for i in 0..<Int(list.num) {
            let value = list.values[i]
            switch String(cString: list.keys[i]!) {
            case "w": width = Int(value.u.int64)
            case "h": height = Int(value.u.int64)
            case "stride": stride = Int(value.u.int64)
            case "data": pixels = value.u.ba.map { Data(bytes: $0.pointee.data, count: $0.pointee.size) }
            default: break
            }
        }
        guard width > 0, height > 0, let pixels, let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        // "bgr0" bytes are B, G, R, unused: a little-endian 32-bit pixel with the unused byte first.
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageByteOrderInfo.order32Little.rawValue
                           | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Returns false on timeout, or when the file ends or fails.
    func waitForEvent(_ id: mpv_event_id, timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let event = mpv_wait_event(handle, deadline.timeIntervalSinceNow)?.pointee else { continue }
            if event.event_id == id { return true }
            if event.event_id == MPV_EVENT_END_FILE || event.event_id == MPV_EVENT_SHUTDOWN { return false }
        }
        return false
    }

    /// Process events until `condition` is true. Returns false on timeout.
    func waitUntil(timeout: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = mpv_wait_event(handle, 0.02)
        }
        return condition()
    }
}
