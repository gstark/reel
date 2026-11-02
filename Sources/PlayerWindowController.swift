import AppKit

/// One window per file: video on top, control bar below, standard title bar above.
final class PlayerWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private static let minimumContentWidth: CGFloat = 520
    private static let audioOnlySize = CGSize(width: 520, height: 0)

    /// Frames on each side of the paused frame for "Copy Frames Around Pause".
    private static let framesAroundPause = 5

    private let url: URL
    private let player = MPVPlayer()
    private let videoView: VideoView
    private let controlBar: ControlBar
    private let onClose: (PlayerWindowController) -> Void
    private var aspectRatio: CGFloat?
    private var hasFitVideo = false
    private var frameIndex: FrameIndex?
    private var isCopying = false

    init(url: URL, onClose: @escaping (PlayerWindowController) -> Void) {
        self.url = url
        self.onClose = onClose
        videoView = VideoView(player: player)
        controlBar = ControlBar(player: player)

        let barHeight = ControlBar.height
        let window = PlayerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540 + barHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = url.lastPathComponent
        window.representedURL = url
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentMinSize = NSSize(width: Self.minimumContentWidth, height: barHeight + 120)
        window.isReleasedWhenClosed = false
        window.displaysWhenScreenProfileChanges = true

        let content = NSView(frame: window.contentLayoutRect)
        videoView.frame = NSRect(x: 0, y: barHeight, width: content.bounds.width, height: content.bounds.height - barHeight)
        videoView.autoresizingMask = [.width, .height]
        controlBar.frame = NSRect(x: 0, y: 0, width: content.bounds.width, height: barHeight)
        controlBar.autoresizingMask = [.width]
        content.addSubview(videoView)
        content.addSubview(controlBar)
        window.contentView = content

        super.init(window: window)
        window.delegate = self

        player.onStateChange = { [weak self] in self?.controlBar.update() }
        player.onVideoSize = { [weak self] in self?.videoSizeChanged($0) }
        player.onFileLoaded = { [weak self] in self?.fileLoaded() }
        player.onError = { [weak self] in self?.failed($0) }
        player.load(url)

        Task { @MainActor [weak self] in
            let index = await FrameIndex.load(url)
            self?.frameIndex = index
            self?.controlBar.frameIndex = index
        }

        // Show the window anyway if mpv never reports a size.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.showIfHidden() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Sizing

    private func videoSizeChanged(_ size: CGSize) {
        aspectRatio = size.width / size.height
        // Fit only once. Later size changes (for example, a new aspect ratio in
        // the stream) must not undo the user's own window size.
        guard !hasFitVideo else { return }
        hasFitVideo = true
        fit(contentTo: size)
        showIfHidden()
    }

    private func fileLoaded() {
        guard player.string("vid") == "no" else { return }
        window?.contentMinSize.height = ControlBar.height
        fit(contentTo: Self.audioOnlySize)
        showIfHidden()
    }

    /// Size the window so the video area matches `videoSize` in points,
    /// scaled down to fit the screen, and center it.
    private func fit(contentTo videoSize: CGSize) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let barHeight = ControlBar.height
        let visible = screen.visibleFrame
        let wasVisible = window.isVisible
        let maxContent = window.contentRect(forFrameRect: visible).size
        let maxVideo = CGSize(width: maxContent.width, height: maxContent.height - barHeight)

        var size = videoSize
        if size.height > 0 {
            let scale = min(1, maxVideo.width / size.width, maxVideo.height / size.height)
            size = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        }
        let width = max(size.width, Self.minimumContentWidth)
        let height = size.height > 0 ? width / (size.width / size.height) : 0
        let contentRect = NSRect(x: 0, y: 0, width: width, height: min(height, maxVideo.height) + barHeight)

        var frame = window.frameRect(forContentRect: contentRect)
        frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
        window.setFrame(frame, display: true, animate: wasVisible)
    }

    private func showIfHidden() {
        guard let window, !window.isVisible else { return }
        showWindow(nil)
        NSApp.activate()
        videoView.useColorProfile(of: window.screen)
    }

    // MARK: - Errors

    private func failed(_ message: String) {
        showIfHidden()
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Cannot play \(window.title)"
        alert.informativeText = message
        alert.beginSheetModal(for: window) { _ in window.close() }
    }

    // MARK: - NSWindowDelegate

    /// Keep the video aspect ratio while the user drags a window edge.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender.inLiveResize, let aspectRatio else { return frameSize }
        let content = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let height = content.width / aspectRatio + ControlBar.height
        return sender.frameRect(forContentRect: NSRect(x: 0, y: 0, width: content.width, height: height)).size
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        window.screen?.visibleFrame ?? newFrame
    }

    func windowDidChangeScreen(_ notification: Notification) {
        videoView.useColorProfile(of: window?.screen)
    }

    func windowDidChangeScreenProfile(_ notification: Notification) {
        videoView.useColorProfile(of: window?.screen)
    }

    func windowWillClose(_ notification: Notification) {
        videoView.videoLayer.destroy()
        player.destroy()
        onClose(self)
    }

    // MARK: - Menu actions (reached through the responder chain)

    @objc func togglePlayPause(_ sender: Any?) { player.togglePause() }
    @objc func skipBackward(_ sender: Any?) { player.seek(by: -5) }
    @objc func skipForward(_ sender: Any?) { player.seek(by: 5) }
    @objc func skipBackwardLong(_ sender: Any?) { player.seek(by: -30) }
    @objc func skipForwardLong(_ sender: Any?) { player.seek(by: 30) }
    @objc func previousFrame(_ sender: Any?) { player.stepFrame(forward: false) }
    @objc func nextFrame(_ sender: Any?) { player.stepFrame(forward: true) }

    // MARK: - Copy frames

    @objc func copy(_ sender: Any?) {
        copyFrames(before: 0, after: 0)
    }

    @objc func copyFramesAroundPause(_ sender: Any?) {
        copyFrames(before: Self.framesAroundPause, after: Self.framesAroundPause)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(copyFramesAroundPause(_:)):
            return !isCopying && player.string("vid") != "no"
        default:
            return true
        }
    }

    /// Save the frames as PNG files and put them on the clipboard.
    /// A hidden mpv instance does the work, so playback stays where it is.
    private func copyFrames(before: Int, after: Int) {
        guard !isCopying, let window else { return }
        player.pause()
        isCopying = true
        let count = before + after + 1
        window.subtitle = count == 1 ? "Copying frame…" : "Copying frames…"

        let source = url
        let time = player.position
        let index = frameIndex
        let baseName = url.deletingPathExtension().lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                let folder = try FrameClipboard.makeFolder()
                return try FrameGrabber.grab(source, at: time, before: before, after: after, into: folder) { time in
                    if let index {
                        return String(format: "%@-f%05d.png", baseName, index.frame(at: time) + 1)
                    }
                    return String(format: "%@-t%.3fs.png", baseName, time)
                }
            }
            DispatchQueue.main.async { self?.finishCopy(result) }
        }
    }

    private func finishCopy(_ result: Result<[FrameGrabber.Frame], Error>) {
        isCopying = false
        guard let window else { return }
        switch result {
        case .success(let frames) where !frames.isEmpty:
            FrameClipboard.copy(frames.map(\.url))
            let status = frames.count == 1 ? "Copied 1 frame" : "Copied \(frames.count) frames"
            window.subtitle = status
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak window] in
                if window?.subtitle == status { window?.subtitle = "" }
            }
        case .success:
            showCopyError("mpv returned no frames.")
        case .failure(let error):
            showCopyError(error.localizedDescription)
        }
    }

    private func showCopyError(_ message: String) {
        guard let window else { return }
        window.subtitle = ""
        let alert = NSAlert()
        alert.messageText = "Cannot copy frames"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
}
