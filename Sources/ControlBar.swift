import AppKit

/// The transport bar under the video. It never overlays the video.
final class ControlBar: NSView {
    static let height: CGFloat = 44

    private let player: MPVPlayer
    private let playButton: NSButton
    private let slider = ScrubSlider()
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")

    /// Exact frame times. Without it, the frame number comes from mpv's estimate.
    var frameIndex: FrameIndex? {
        didSet { update() }
    }

    init(player: MPVPlayer) {
        self.player = player
        playButton = ControlBar.button("pause.fill", "Play/Pause (Space)")
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor

        playButton.target = self
        playButton.action = #selector(togglePause)

        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true
        slider.refusesFirstResponder = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(scrub)
        slider.onRelease = { [weak self] in
            guard let self else { return }
            player.seek(to: slider.doubleValue, exact: true)
        }

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let transport = NSStackView(views: [
            action(ControlBar.button("gobackward.30", "Back 30 seconds (⇧←)"), #selector(back30)),
            action(ControlBar.button("gobackward.5", "Back 5 seconds (←)"), #selector(back5)),
            action(ControlBar.button("backward.frame.fill", "Previous frame (,)"), #selector(previousFrame)),
            playButton,
            action(ControlBar.button("forward.frame.fill", "Next frame (.)"), #selector(nextFrame)),
            action(ControlBar.button("goforward.5", "Forward 5 seconds (→)"), #selector(forward5)),
            action(ControlBar.button("goforward.30", "Forward 30 seconds (⇧→)"), #selector(forward30)),
        ])
        transport.spacing = 4

        // A nil target sends the action through the responder chain to the window controller.
        let copyButton = ControlBar.button("photo.stack", "Copy frames around this frame (⇧⌘C)")
        copyButton.action = #selector(PlayerWindowController.copyFramesAroundPause(_:))

        let row = NSStackView(views: [transport, slider, timeLabel, copyButton])
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update() {
        playButton.image = ControlBar.symbol(player.isPaused ? "play.fill" : "pause.fill")
        if !slider.isScrubbing {
            slider.maxValue = max(player.duration, 1)
            slider.doubleValue = player.position
        }
        let position = slider.isScrubbing ? slider.doubleValue : player.position
        let duration = ControlBar.format(player.duration)
        if player.isPaused && !slider.isScrubbing {
            let time = "\(ControlBar.format(position, milliseconds: true)) / \(duration)"
            timeLabel.stringValue = frameText(at: position).map { "\($0)   \(time)" } ?? time
        } else {
            timeLabel.stringValue = "\(ControlBar.format(position)) / \(duration)"
        }
    }

    /// "Frame 573 of 1338", one-based. "≈" marks an estimate from mpv.
    private func frameText(at position: Double) -> String? {
        if let frameIndex {
            return "Frame \(frameIndex.frame(at: position) + 1) of \(frameIndex.count)"
        }
        guard let frame = player.int("estimated-frame-number") else { return nil }
        let total = player.int("estimated-frame-count").map { " of \($0)" } ?? ""
        return "≈ Frame \(frame + 1)\(total)"
    }

    // MARK: - Actions

    @objc private func togglePause() { player.togglePause() }
    @objc private func back30() { player.seek(by: -30) }
    @objc private func back5() { player.seek(by: -5) }
    @objc private func forward5() { player.seek(by: 5) }
    @objc private func forward30() { player.seek(by: 30) }
    @objc private func previousFrame() { player.stepFrame(forward: false) }
    @objc private func nextFrame() { player.stepFrame(forward: true) }

    @objc private func scrub() {
        player.seek(to: slider.doubleValue, exact: false)
        update()
    }

    // MARK: - Helpers

    private func action(_ button: NSButton, _ selector: Selector) -> NSButton {
        button.target = self
        button.action = selector
        return button
    }

    private static func button(_ symbolName: String, _ tooltip: String) -> NSButton {
        let button = NSButton(image: symbol(symbolName), target: nil, action: nil)
        button.isBordered = false
        button.refusesFirstResponder = true
        button.contentTintColor = .labelColor
        button.toolTip = tooltip
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private static func symbol(_ name: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        return NSImage(systemSymbolName: name, accessibilityDescription: name)!.withSymbolConfiguration(config)!
    }

    static func format(_ seconds: Double, milliseconds: Bool = false) -> String {
        let clamped = max(seconds, 0)
        let total = Int(clamped)
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        let text = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        guard milliseconds else { return text }
        return text + String(format: ".%03d", Int((clamped - Double(total)) * 1000))
    }
}

/// An NSSlider that reports when the user holds and releases it.
final class ScrubSlider: NSSlider {
    private(set) var isScrubbing = false
    var onRelease: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        isScrubbing = true
        super.mouseDown(with: event) // Runs the tracking loop until mouse up.
        isScrubbing = false
        onRelease?()
    }
}
