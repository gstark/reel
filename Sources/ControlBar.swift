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

    /// The duration of one frame. The finest scrub level moves one frame for a few points of drag.
    var frameDuration: () -> Double = { 1.0 / 30 }

    func setMarks(in start: Double?, out end: Double?) {
        slider.marks = (start, end)
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
            update()
        }

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let transport = NSStackView(views: [
            action(ControlBar.button("gobackward.30", "Back 30 seconds (⇧←)"), #selector(back30)),
            action(ControlBar.button("gobackward.5", "Back 5 seconds (←)"), #selector(back5)),
            ControlBar.button("backward.frame.fill", "Previous frame (,)", #selector(PlayerWindowController.previousFrame(_:))),
            playButton,
            ControlBar.button("forward.frame.fill", "Next frame (.)", #selector(PlayerWindowController.nextFrame(_:))),
            action(ControlBar.button("goforward.5", "Forward 5 seconds (→)"), #selector(forward5)),
            action(ControlBar.button("goforward.30", "Forward 30 seconds (⇧→)"), #selector(forward30)),
        ])
        transport.spacing = 4

        let copyButton = ControlBar.button("photo.stack", "Copy frames around this frame (⇧⌘C)",
                                           #selector(PlayerWindowController.copyFramesAroundPause(_:)))

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
        slider.fineSecondsPerPoint = frameDuration() / 6
        let position = slider.isScrubbing ? slider.doubleValue : player.position
        let duration = ControlBar.format(player.duration)
        if slider.isScrubbing, let level = slider.level.name {
            timeLabel.stringValue = "\(level)   \(ControlBar.format(position, milliseconds: true)) / \(duration)"
        } else if player.isPaused && !slider.isScrubbing {
            let time = "\(ControlBar.format(position, milliseconds: true)) / \(duration)"
            timeLabel.stringValue = frameText(at: position).map { "\($0)   \(time)" } ?? time
        } else {
            timeLabel.stringValue = speedText() + "\(ControlBar.format(position)) / \(duration)"
        }
    }

    /// "◀ 2×" while playing backward or at another speed than normal.
    private func speedText() -> String {
        guard player.speed != 1 || !player.isForward else { return "" }
        let speed = switch player.speed {
        case 0.25: "¼×"
        case 0.5: "½×"
        default: String(format: "%g×", player.speed)
        }
        return (player.isForward ? "" : "◀ ") + speed + "   "
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
    @objc private func scrub() {
        // The slower levels are for exact positions, so they seek to the exact frame.
        player.seek(to: slider.doubleValue, exact: slider.level != .normal)
        update()
    }

    // MARK: - Helpers

    private func action(_ button: NSButton, _ selector: Selector) -> NSButton {
        button.target = self
        button.action = selector
        return button
    }

    /// A nil target sends the action through the responder chain to the window controller.
    private static func button(_ symbolName: String, _ tooltip: String, _ action: Selector? = nil) -> NSButton {
        let button = NSButton(image: symbol(symbolName), target: nil, action: action)
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

/// The position slider. It reports when the user holds and releases it.
///
/// A drag away from the slider scrubs slower, as in the iOS scrubber: half speed, quarter speed,
/// and then a fine level that moves one frame for a few points. The value follows the drag
/// relative to its start, so a change of level does not make the value jump.
final class ScrubSlider: NSSlider {
    enum Level {
        case normal, half, quarter, fine

        var name: String? {
            switch self {
            case .normal: nil
            case .half: "Half-speed scrubbing"
            case .quarter: "Quarter-speed scrubbing"
            case .fine: "Fine scrubbing"
            }
        }
    }

    private(set) var isScrubbing = false
    private(set) var level = Level.normal
    var onRelease: (() -> Void)?
    /// The seconds that one point of drag moves at the fine level.
    var fineSecondsPerPoint = 1.0 / 180

    var marks: (in: Double?, out: Double?) {
        get { (cell as? ScrubSliderCell)?.marks ?? (nil, nil) }
        set {
            (cell as? ScrubSliderCell)?.marks = newValue
            needsDisplay = true
        }
    }

    override class var cellClass: AnyClass? {
        get { ScrubSliderCell.self }
        set {}
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window, let cell = cell as? NSSliderCell else { return }
        isScrubbing = true
        level = .normal
        let bar = cell.barRect(flipped: isFlipped)
        let travel = max(bar.width - cell.knobThickness, 1)
        let range = maxValue - minValue

        // A click on the bar moves the knob there. A click on the knob keeps the value.
        var lastX = convert(event.locationInWindow, from: nil).x
        if !cell.knobRect(flipped: isFlipped).insetBy(dx: -2, dy: -4).contains(convert(event.locationInWindow, from: nil)) {
            let fraction = (lastX - bar.minX - cell.knobThickness / 2) / travel
            doubleValue = minValue + Double(min(max(fraction, 0), 1)) * range
            sendAction(action, to: target)
        }

        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            let point = convert(next.locationInWindow, from: nil)
            let distance = max(abs(point.y - bounds.midY) - bounds.height / 2, 0)
            level = switch distance {
            case ..<40: .normal
            case ..<90: .half
            case ..<140: .quarter
            default: .fine
            }
            let points = Double(point.x - lastX)
            lastX = point.x
            let secondsPerPoint = range / Double(travel)
            let delta = switch level {
            case .normal: points * secondsPerPoint
            case .half: points * secondsPerPoint / 2
            case .quarter: points * secondsPerPoint / 4
            case .fine: points * min(fineSecondsPerPoint, secondsPerPoint / 8)
            }
            doubleValue = min(max(doubleValue + delta, minValue), maxValue)
            sendAction(action, to: target)
        }

        isScrubbing = false
        level = .normal
        onRelease?()
    }
}

/// Draws the in and out marks on the slider bar, under the knob.
final class ScrubSliderCell: NSSliderCell {
    var marks: (in: Double?, out: Double?) = (nil, nil)

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        super.drawBar(inside: rect, flipped: flipped)
        guard maxValue > minValue, marks.in != nil || marks.out != nil else { return }
        let travel = rect.width - knobThickness
        func x(_ value: Double) -> CGFloat {
            rect.minX + knobThickness / 2 + CGFloat((value - minValue) / (maxValue - minValue)) * travel
        }
        let start = marks.in.map(x), end = marks.out.map(x)
        let left = start ?? end!, right = end ?? start!
        NSColor.systemYellow.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: left - 1, y: rect.midY - 2, width: max(right - left, 0) + 2, height: 4),
                     xRadius: 2, yRadius: 2).fill()
    }
}
