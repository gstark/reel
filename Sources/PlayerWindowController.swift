import AppKit

/// One window per file: video on top, control bar below, standard title bar above.
/// While playback is paused, the frame strip opens under the control bar.
final class PlayerWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private static let minimumContentWidth: CGFloat = 520
    private static let audioOnlySize = CGSize(width: 520, height: 0)

    /// Frames on each side of the paused frame for "Copy Frames Around Pause".
    private static let framesAroundPause = 5

    private let url: URL
    private let player = MPVPlayer()
    private let videoView: VideoView
    private let controlBar: ControlBar
    private let content: PlayerContentView
    private let navigator: FrameNavigator
    private let shuttle: Shuttle
    private let onClose: (PlayerWindowController) -> Void
    private var aspectRatio: CGFloat?
    private var hasFitVideo = false
    private var hasVideo = false
    private var frameIndex: FrameIndex?
    private var isCopying = false
    private lazy var exports = ExportCoordinator(
        url: url, player: player, navigator: navigator, controlBar: controlBar,
        window: { [weak self] in self?.window },
        frameIndex: { [weak self] in self?.frameIndex },
        showStatus: { [weak self] in self?.showStatus($0) },
        showToast: { [weak self] in self?.showToast($0, image: $1) })
    private var keyMonitor: Any?

    /// The window frame before the strip opened, and the frame after.
    private var stripGrowth: (before: NSRect, after: NSRect)?
    private var hideStripWork: DispatchWorkItem?

    init(url: URL, onClose: @escaping (PlayerWindowController) -> Void) {
        self.url = url
        self.onClose = onClose
        videoView = VideoView(player: player)
        controlBar = ControlBar(player: player)
        navigator = FrameNavigator(url: url, player: player)
        content = PlayerContentView(video: videoView, controlBar: controlBar, strip: navigator.strip)
        shuttle = Shuttle(player: player) { [weak navigator] in navigator?.step(by: $0) }

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

        window.contentView = content

        super.init(window: window)
        window.delegate = self

        controlBar.frameDuration = { [weak navigator] in navigator?.frameDuration ?? 1.0 / 30 }
        navigator.onStatus = { [weak self] in self?.showStatus($0) }
        controlBar.onStatus = { [weak self] in self?.showControlStatus($0) }
        navigator.onMarksChange = { [weak self] in
            guard let self else { return }
            controlBar.setMarks(in: navigator.inPoint, out: navigator.outPoint)
        }

        // J, K, and L need key-up events, which menu items do not get.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, event.window === self.window, shuttle.handle(event) else { return event }
            return nil
        }

        player.onStateChange = { [weak self] in self?.playerStateChanged() }
        player.onVideoSize = { [weak self] in self?.videoSizeChanged($0) }
        player.onFileLoaded = { [weak self] in self?.fileLoaded() }
        player.onError = { [weak self] in self?.failed($0) }
        player.load(url)

        Task { @MainActor [weak self] in
            let index = await FrameIndex.load(url)
            self?.frameIndex = index
            self?.controlBar.frameIndex = index
            self?.navigator.index = index
        }

        // Show the window anyway if mpv never reports a size.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.showIfHidden() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Sizing

    /// The height of everything under the video.
    private var chromeHeight: CGFloat {
        ControlBar.height + (content.showsStrip ? FrameStripView.height : 0)
    }

    private func videoSizeChanged(_ size: CGSize) {
        aspectRatio = size.width / size.height
        navigator.strip.aspectRatio = size.width / size.height
        hasVideo = true
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
        let barHeight = chromeHeight
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

    // MARK: - Frame strip

    private func playerStateChanged() {
        controlBar.update()
        navigator.playerStateChanged()
        updateStrip()
    }

    /// Open the strip at once on pause. Close it only after playback runs for a moment,
    /// because frame steps in mpv play for a short time.
    private func updateStrip() {
        guard hasVideo else { return }
        if player.isPaused || shuttle.isHoldingStop {
            hideStripWork?.cancel()
            hideStripWork = nil
            setStripVisible(true)
        } else if content.showsStrip, hideStripWork == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                hideStripWork = nil
                if !player.isPaused && !shuttle.isHoldingStop { setStripVisible(false) }
            }
            hideStripWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    /// The window grows down to make space for the strip, so the video keeps its size.
    /// It shrinks back when the strip closes. In full screen, the video gets smaller instead.
    private func setStripVisible(_ visible: Bool) {
        guard let window, visible != content.showsStrip else { return }
        let stripHeight = FrameStripView.height
        content.showsStrip = visible
        navigator.isActive = visible
        window.contentMinSize.height += visible ? stripHeight : -stripHeight
        guard !window.styleMask.contains(.fullScreen) else { return }

        if visible {
            var frame = window.frame
            frame.origin.y -= stripHeight
            frame.size.height += stripHeight
            if let screen = window.screen?.visibleFrame {
                // Move up at the bottom of the screen. If the window is as tall as the screen, the video gets smaller.
                frame.origin.y = max(frame.origin.y, screen.minY)
                frame.size.height = min(frame.height, screen.maxY - frame.minY)
            }
            stripGrowth = (window.frame, frame)
            window.setFrame(frame, display: true)
        } else if let growth = stripGrowth {
            stripGrowth = nil
            if window.frame == growth.after {
                window.setFrame(growth.before, display: true)
            } else {
                // The user moved or resized the window. Keep the top edge and remove the added height.
                var frame = window.frame
                let added = growth.after.height - growth.before.height
                frame.origin.y += added
                frame.size.height -= added
                window.setFrame(frame, display: true)
            }
        }
    }

    // MARK: - Status

    /// Show a short text under the window title. Text that ends without "…" goes away after 3 seconds.
    private func showStatus(_ text: String?) {
        guard let window else { return }
        window.subtitle = text ?? ""
        guard let text, !text.hasSuffix("…") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak window] in
            if window?.subtitle == text { window?.subtitle = "" }
        }
    }

    private var controlStatus: String?

    /// Show the playback speed or the scrub level under the window title while it applies.
    /// nil removes it, unless other status text replaced it.
    private func showControlStatus(_ text: String?) {
        guard let window else { return }
        if let text {
            window.subtitle = text
        } else if window.subtitle == controlStatus {
            window.subtitle = ""
        }
        controlStatus = text
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
        let height = content.width / aspectRatio + chromeHeight
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
        exports.cancel()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
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
    @objc func previousFrame(_ sender: Any?) { navigator.step(by: -1) }
    @objc func nextFrame(_ sender: Any?) { navigator.step(by: 1) }
    @objc func previousChange(_ sender: Any?) { navigator.findChange(forward: false) }
    @objc func nextChange(_ sender: Any?) { navigator.findChange(forward: true) }

    @objc func playBackward(_ sender: Any?) { shuttle.playBackward() }
    @objc func stopPlayback(_ sender: Any?) { shuttle.stop() }
    @objc func playForward(_ sender: Any?) { shuttle.playForward() }

    /// A context menu item carries the frame time. The menu bar item uses the current frame.
    @objc func markIn(_ sender: Any?) { navigator.markIn(at: (sender as? NSMenuItem)?.representedObject as? Double) }
    @objc func markOut(_ sender: Any?) { navigator.markOut(at: (sender as? NSMenuItem)?.representedObject as? Double) }
    @objc func clearMarks(_ sender: Any?) { navigator.clearMarks() }
    @objc func goToIn(_ sender: Any?) { navigator.inPoint.map(navigator.select) }
    @objc func goToOut(_ sender: Any?) { navigator.outPoint.map(navigator.select) }

    // MARK: - Export

    /// While an export runs, the same item cancels it.
    @objc func exportMarkedRange(_ sender: Any?) {
        exports.isRunning ? exports.cancel() : exports.exportClip()
    }

    @objc func exportMarkedFrames(_ sender: Any?) { exports.exportFrames() }

    /// A new toast replaces the one on screen.
    private func showToast(_ toast: ExportToast, image: CGImage?) {
        content.toast?.close()
        toast.image = image
        toast.onDismiss = { [weak self, weak toast] in
            if let self, content.toast === toast { content.toast = nil }
        }
        content.toast = toast
        content.layoutSubtreeIfNeeded()
        toast.present()
    }

    // MARK: - Copy frames

    @objc func copy(_ sender: Any?) {
        copyFrames(at: navigator.currentTime, before: 0, after: 0)
    }

    @objc func copyFramesAroundPause(_ sender: Any?) {
        copyFrames(at: navigator.currentTime, before: Self.framesAroundPause, after: Self.framesAroundPause)
    }

    /// Ask first for a long range, because each frame is a full-size PNG file.
    @objc func copyMarkedFrames(_ sender: Any?) {
        guard let window, let start = navigator.inPoint, let end = navigator.outPoint,
              let count = navigator.markedFrameCount else { return }
        guard count > 100 else {
            copyFrames(at: start, before: 0, after: .max, through: end)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Copy \(count) frames?"
        alert.informativeText = "Each frame becomes a full-resolution PNG file. A long range can take a while and use a lot of disk space."
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.copyFrames(at: start, before: 0, after: .max, through: end)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(exportMarkedRange(_:)):
            menuItem.title = exports.isRunning ? "Cancel Export" : "Export In to Out…"
            return exports.isRunning || exports.canExport
        case #selector(exportMarkedFrames(_:)):
            return !exports.isRunning && !isCopying && exports.canExport
        case #selector(copy(_:)), #selector(copyFramesAroundPause(_:)):
            return !isCopying && hasVideo
        case #selector(copyMarkedFrames(_:)):
            return !isCopying && navigator.markedFrameCount != nil
        case #selector(previousChange(_:)), #selector(nextChange(_:)), #selector(markIn(_:)), #selector(markOut(_:)):
            return hasVideo
        case #selector(goToIn(_:)):
            return navigator.inPoint != nil
        case #selector(goToOut(_:)):
            return navigator.outPoint != nil
        case #selector(clearMarks(_:)):
            return navigator.inPoint != nil || navigator.outPoint != nil
        default:
            return true
        }
    }

    /// Save the frames as PNG files and put them on the clipboard.
    /// A hidden mpv instance does the work, so playback stays where it is.
    private func copyFrames(at time: Double, before: Int, after: Int, through end: Double = .infinity) {
        guard !isCopying else { return }
        player.pause()
        isCopying = true
        showStatus(before == 0 && after == 0 ? "Copying frame…" : "Copying frames…")

        let source = url
        let index = frameIndex
        let baseName = url.deletingPathExtension().lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                let folder = try FrameClipboard.makeFolder()
                return try FrameGrabber.grab(source, at: time, before: before, after: after, through: end,
                                             into: folder) { time in
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
        switch result {
        case .success(let frames) where !frames.isEmpty:
            FrameClipboard.copy(frames.map(\.url))
            showStatus(frames.count == 1 ? "Copied 1 frame" : "Copied \(frames.count) frames")
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

/// Lays out the video, the control bar, and the frame strip from top to bottom.
private final class PlayerContentView: NSView {
    private let video: NSView
    private let controlBar: NSView
    private let strip: NSView

    var showsStrip = false {
        didSet {
            strip.isHidden = !showsStrip
            needsLayout = true
        }
    }

    /// The export announcement, centered over the bottom of the video.
    var toast: ExportToast? {
        didSet {
            if let toast, toast !== oldValue {
                addSubview(toast)
                needsLayout = true
            }
        }
    }

    init(video: NSView, controlBar: NSView, strip: NSView) {
        self.video = video
        self.controlBar = controlBar
        self.strip = strip
        super.init(frame: .zero)
        strip.isHidden = true
        [video, controlBar, strip].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let stripHeight = showsStrip ? FrameStripView.height : 0
        let chrome = stripHeight + ControlBar.height
        strip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: stripHeight)
        controlBar.frame = NSRect(x: 0, y: stripHeight, width: bounds.width, height: ControlBar.height)
        video.frame = NSRect(x: 0, y: chrome, width: bounds.width, height: max(bounds.height - chrome, 0))
        if let toast {
            let size = toast.fittingSize
            let width = min(size.width, bounds.width - 2 * ExportToast.gap)
            toast.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: chrome + ExportToast.gap,
                                 width: width, height: size.height)
        }
    }
}
