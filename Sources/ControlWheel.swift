import AppKit

/// The control bar commands as a flower of round buttons around the pointer.
///
/// The window controller opens the wheel while the left Control key is held and closes it on release.
/// Play/Pause is the middle. Commands that go back sit on the left, commands that go forward sit on
/// the right, and the speed commands sit at the bottom. Each petal owns its full slice of the circle,
/// so the pointer only needs to move in the right direction. A click runs the command and keeps the
/// wheel open, so a petal can be clicked again and again.
final class ControlWheel: NSView {
    struct Command {
        let title: String
        let symbol: String
        let action: Selector
    }

    /// Clockwise from the top.
    static let petals: [Command] = [
        Command(title: "Copy frames", symbol: "photo.stack", action: #selector(PlayerWindowController.copyFramesAroundPause(_:))),
        Command(title: "Next frame", symbol: "forward.frame.fill", action: #selector(PlayerWindowController.nextFrame(_:))),
        Command(title: "Forward 5 s", symbol: "goforward.5", action: #selector(PlayerWindowController.skipForward(_:))),
        Command(title: "Forward 30 s", symbol: "goforward.30", action: #selector(PlayerWindowController.skipForwardLong(_:))),
        Command(title: "Faster", symbol: "hare.fill", action: #selector(PlayerWindowController.increaseSpeed(_:))),
        Command(title: "Normal speed", symbol: "", action: #selector(PlayerWindowController.resetSpeed(_:))),
        Command(title: "Slower", symbol: "tortoise.fill", action: #selector(PlayerWindowController.decreaseSpeed(_:))),
        Command(title: "Back 30 s", symbol: "gobackward.30", action: #selector(PlayerWindowController.skipBackwardLong(_:))),
        Command(title: "Back 5 s", symbol: "gobackward.5", action: #selector(PlayerWindowController.skipBackward(_:))),
        Command(title: "Previous frame", symbol: "backward.frame.fill", action: #selector(PlayerWindowController.previousFrame(_:))),
    ]
    static let middle = Command(title: "Play/Pause", symbol: "", action: #selector(PlayerWindowController.togglePlayPause(_:)))

    private static let middleRadius: CGFloat = 50
    private static let ringRadius: CGFloat = 118
    private static let petalRadius: CGFloat = 32
    /// The pointer selects a petal up to this distance from the middle.
    private static let reach: CGFloat = 220
    private static var outerRadius: CGFloat { ringRadius + petalRadius }

    var isPaused: () -> Bool = { true }
    var speed: () -> Double = { 1 }
    var isEnabled: (Selector) -> Bool = { _ in true }
    var perform: (Selector) -> Void = { _ in }

    private var center = NSPoint.zero
    /// nil is the middle. -1 is no command.
    private var hovered: Int? = -1
    /// 0...1 while the petals open out from the middle.
    private var bloom: CGFloat = 1
    private var bloomTimer: Timer?

    /// Flipped, so the wheel keeps its place under the pointer when the window grows down for the frame strip.
    override var isFlipped: Bool { true }

    // MARK: - Open and close

    /// Open the wheel around the pointer, and keep it inside the view.
    func open(in parent: NSView, at windowPoint: NSPoint?) {
        frame = parent.bounds
        autoresizingMask = [.width, .height]
        parent.addSubview(self)
        let point = windowPoint.map { convert($0, from: nil) } ?? NSPoint(x: bounds.midX, y: bounds.midY)
        let margin = Self.outerRadius + 8
        func clamp(_ value: CGFloat, _ length: CGFloat) -> CGFloat {
            length > 2 * margin ? min(max(value, margin), length - margin) : length / 2
        }
        center = NSPoint(x: clamp(point.x, bounds.width), y: clamp(point.y, bounds.height))
        hover(at: point)

        bloom = 0
        let start = Date()
        bloomTimer?.invalidate()
        bloomTimer = .scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let t = min(Date().timeIntervalSince(start) / 0.14, 1)
            bloom = 1 - pow(1 - t, 3)
            needsDisplay = true
            if t >= 1 { timer.invalidate() }
        }
    }

    func close() {
        bloomTimer?.invalidate()
        bloomTimer = nil
        removeFromSuperview()
    }

    /// Redraw after the player state changes.
    func refresh() { needsDisplay = true }

    // MARK: - Pointer

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Take every click in the window, so a Control-click does not open a context menu under the wheel.
        frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hover(at: point)
        guard let command = command(at: point), isEnabled(command.action) else { return }
        perform(command.action)
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {}
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    private func hover(at point: NSPoint) {
        let index = index(at: point)
        guard index != hovered else { return }
        hovered = index
        needsDisplay = true
    }

    /// nil is the middle. -1 is outside the reach.
    private func index(at point: NSPoint) -> Int? {
        let dx = point.x - center.x, dy = point.y - center.y
        let distance = hypot(dx, dy)
        if distance <= Self.middleRadius + 6 { return nil }
        if distance > Self.reach { return -1 }
        // 0 is straight up, clockwise. The view is flipped, so up is -y.
        let angle = atan2(dx, -dy)
        let slice = 2 * CGFloat.pi / CGFloat(Self.petals.count)
        let turns = (angle + slice / 2).truncatingRemainder(dividingBy: 2 * .pi)
        return Int(((turns < 0 ? turns + 2 * .pi : turns) / slice).rounded(.down)) % Self.petals.count
    }

    private func command(at point: NSPoint) -> Command? {
        switch index(at: point) {
        case nil: Self.middle
        case let index? where index >= 0: Self.petals[index]
        default: nil
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let fade = bloom
        // A soft shade behind the flower keeps it readable over a bright video.
        let shade = NSGradient(colors: [NSColor(white: 0, alpha: 0.45 * fade), NSColor(white: 0, alpha: 0)])
        shade?.draw(fromCenter: center, radius: 0, toCenter: center, radius: Self.outerRadius + 50, options: [])

        let ring = Self.middleRadius + (Self.ringRadius - Self.middleRadius) * bloom
        for (index, command) in Self.petals.enumerated() {
            let angle = 2 * CGFloat.pi * CGFloat(index) / CGFloat(Self.petals.count)
            let point = NSPoint(x: center.x + sin(angle) * ring, y: center.y - cos(angle) * ring)
            let isHovered = hovered == index
            let radius = Self.petalRadius * (isHovered ? 1.15 : 1) * (0.6 + 0.4 * bloom)
            drawDisk(at: point, radius: radius, highlighted: isHovered, alpha: fade)
            let enabled = isEnabled(command.action)
            if command.action == #selector(PlayerWindowController.resetSpeed(_:)) {
                drawText(PlaybackSpeed.label(speed()), at: point, size: 15, weight: .semibold, alpha: fade)
            } else {
                drawSymbol(command.symbol, at: point, size: 17, alpha: fade * (enabled ? 1 : 0.3))
            }
        }

        drawDisk(at: center, radius: Self.middleRadius, highlighted: hovered == nil, alpha: fade)
        let label = switch hovered {
        case nil: isPaused() ? "Play" : "Pause"
        case let index? where index >= 0: Self.petals[index].title
        default: speed() == 1 ? "" : PlaybackSpeed.label(speed())
        }
        drawSymbol(isPaused() ? "play.fill" : "pause.fill", at: NSPoint(x: center.x, y: center.y - 9), size: 24, alpha: fade)
        drawText(label, at: NSPoint(x: center.x, y: center.y + 22), size: 10, weight: .medium, alpha: fade * 0.85)
    }

    private func drawDisk(at point: NSPoint, radius: CGFloat, highlighted: Bool, alpha: CGFloat) {
        let disk = NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius))
        (highlighted ? NSColor.controlAccentColor : NSColor(white: 0.1, alpha: 0.85)).withAlphaComponent(alpha * (highlighted ? 1 : 0.85)).setFill()
        disk.fill()
        NSColor(white: 1, alpha: 0.18 * alpha).setStroke()
        disk.lineWidth = 1
        disk.stroke()
    }

    private func drawSymbol(_ name: String, at point: NSPoint, size: CGFloat, alpha: CGFloat) {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
            .applying(.init(paletteColors: [.white]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let rect = NSRect(x: point.x - image.size.width / 2, y: point.y - image.size.height / 2,
                          width: image.size.width, height: image.size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
    }

    private func drawText(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(white: 1, alpha: alpha),
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        string.draw(at: NSPoint(x: point.x - textSize.width / 2, y: point.y - textSize.height / 2))
    }
}
