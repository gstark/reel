import Foundation
import Libmpv

/// Thin wrapper around a libmpv handle. All callbacks run on the main thread.
final class MPVPlayer {
    private(set) var handle: OpaquePointer?

    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPaused = false
    private(set) var speed: Double = 1
    /// False while mpv plays backward (`play-direction=backward`).
    private(set) var isForward = true
    private(set) var videoSize: CGSize?

    var onStateChange: (() -> Void)?
    var onVideoSize: ((CGSize) -> Void)?
    var onFileLoaded: (() -> Void)?
    var onError: ((String) -> Void)?

    private var displayWidth: Int64 = 0
    private var displayHeight: Int64 = 0

    init() {
        guard let handle = mpv_create() else { fatalError("mpv_create failed") }
        self.handle = handle

        setOption("vo", "libmpv")
        setOption("hwdec", "auto-safe")
        setOption("keep-open", "yes")
        setOption("idle", "yes")
        setOption("input-default-bindings", "no")
        setOption("input-vo-keyboard", "no")
        setOption("osc", "no")
        // Use the display ICC profile that VideoLayer passes to the render context.
        setOption("icc-profile-auto", "yes")

        guard mpv_initialize(handle) >= 0 else { fatalError("mpv_initialize failed") }

        mpv_observe_property(handle, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 0, "speed", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "play-direction", MPV_FORMAT_STRING)
        mpv_observe_property(handle, 0, "dwidth", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 0, "dheight", MPV_FORMAT_INT64)

        // The callback holds a retained reference. `destroy()` releases it.
        mpv_set_wakeup_callback(handle, { context in
            let player = Unmanaged<MPVPlayer>.fromOpaque(context!).takeUnretainedValue()
            DispatchQueue.main.async { player.drainEvents() }
        }, Unmanaged.passRetained(self).toOpaque())
    }

    /// The render context must be freed before this is called.
    func destroy() {
        guard let handle else { return }
        mpv_set_wakeup_callback(handle, nil, nil)
        self.handle = nil
        mpv_terminate_destroy(handle)
        Unmanaged.passUnretained(self).release()
    }

    // MARK: - Commands

    func load(_ url: URL) {
        command("loadfile", url.isFileURL ? url.path : url.absoluteString)
    }

    /// Play resumes forward at normal speed.
    func togglePause() {
        if isPaused { play(forward: true, speed: 1) } else { pause() }
    }

    func play(forward: Bool, speed: Double) {
        if forward != isForward { command("set", "play-direction", forward ? "forward" : "backward") }
        if speed != self.speed { command("set", "speed", String(speed)) }
        command("set", "pause", "no")
    }

    /// Pause and go back to normal speed.
    func stop() {
        pause()
        if speed != 1 { command("set", "speed", "1") }
    }

    func pause() {
        guard let handle else { return }
        var yes: Int32 = 1
        mpv_set_property(handle, "pause", MPV_FORMAT_FLAG, &yes)
    }

    func seek(by seconds: Double) {
        command("seek", String(seconds), "relative+exact")
    }

    func seek(to seconds: Double, exact: Bool) {
        command("seek", String(seconds), exact ? "absolute+exact" : "absolute+keyframes")
    }

    func stepFrame(forward: Bool) {
        // In backward playback mode, mpv swaps the direction of the two commands.
        command(forward == isForward ? "frame-step" : "frame-back-step")
    }

    /// Loop playback between two times. nil turns the loop off.
    func setLoop(_ range: ClosedRange<Double>?) {
        command("set", "ab-loop-a", range.map { String($0.lowerBound) } ?? "no")
        command("set", "ab-loop-b", range.map { String($0.upperBound) } ?? "no")
    }

    func string(_ property: String) -> String? {
        guard let handle, let value = mpv_get_property_string(handle, property) else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }

    func double(_ property: String) -> Double? {
        guard let handle else { return nil }
        var value = 0.0
        return mpv_get_property(handle, property, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
    }

    func int(_ property: String) -> Int? {
        guard let handle else { return nil }
        var value: Int64 = 0
        return mpv_get_property(handle, property, MPV_FORMAT_INT64, &value) >= 0 ? Int(value) : nil
    }

    private func command(_ args: String...) {
        guard let handle else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
        defer { cargs.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        mpv_command_async(handle, 0, &cargs)
    }

    private func setOption(_ name: String, _ value: String) {
        mpv_set_option_string(handle, name, value)
    }

    // MARK: - Events

    private func drainEvents() {
        while let handle, let event = mpv_wait_event(handle, 0)?.pointee, event.event_id != MPV_EVENT_NONE {
            switch event.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                handleProperty(event.data.assumingMemoryBound(to: mpv_event_property.self).pointee)
            case MPV_EVENT_FILE_LOADED:
                onFileLoaded?()
            case MPV_EVENT_END_FILE:
                let endFile = event.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if endFile.reason == MPV_END_FILE_REASON_ERROR {
                    onError?(String(cString: mpv_error_string(endFile.error)))
                }
            default:
                break
            }
        }
    }

    private func handleProperty(_ property: mpv_event_property) {
        let name = String(cString: property.name)
        let data = property.data

        switch name {
        case "time-pos":
            position = data?.load(as: Double.self) ?? 0
        case "duration":
            duration = data?.load(as: Double.self) ?? 0
        case "pause":
            isPaused = (data?.load(as: Int32.self) ?? 0) != 0
        case "speed":
            speed = data?.load(as: Double.self) ?? 1
        case "play-direction":
            let value = data?.load(as: UnsafePointer<CChar>?.self).map { String(cString: $0) }
            isForward = value != "backward"
        case "dwidth", "dheight":
            let value = data?.load(as: Int64.self) ?? 0
            if name == "dwidth" { displayWidth = value } else { displayHeight = value }
            updateVideoSize()
            return
        default:
            return
        }
        onStateChange?()
    }

    private func updateVideoSize() {
        guard displayWidth > 0, displayHeight > 0 else { return }
        let size = CGSize(width: CGFloat(displayWidth), height: CGFloat(displayHeight))
        guard size != videoSize else { return }
        videoSize = size
        onVideoSize?(size)
    }
}
