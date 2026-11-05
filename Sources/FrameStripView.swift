import AppKit

/// The row of frames under the control bar while playback is paused, as in a video editor.
///
/// The middle slot is the current frame. The view only shows frames and reports input:
/// - A move over a slot skims: the video shows that frame until the pointer leaves the strip.
/// - A click goes to the frame. A drag then moves the strip like a ruler, one slot per frame.
/// - A scroll (trackpad or wheel) steps frames.
/// - A right-click opens a menu that copies the time code and frame number of that frame.
final class FrameStripView: NSView {
    static let height: CGFloat = 92

    struct Slot {
        let time: Double
        /// One-based frame number, or nil when only the time is known.
        let number: Int?
        let image: CGImage?
        /// The frame differs from the frame before it.
        let changed: Bool
    }

    /// One entry per visible slot. nil is a slot before the start or after the end of the file.
    var slots: [Slot?] = [] { didSet { needsDisplay = true } }
    var marks: (in: Double?, out: Double?) = (nil, nil) { didSet { needsDisplay = true } }
    /// The number of frames in the file. The middle label shows it: "573 of 1338".
    var frameCount: Int? { didSet { needsDisplay = true } }
    var aspectRatio: CGFloat = 16 / 9 {
        didSet { if aspectRatio != oldValue { layoutChanged() } }
    }

    var onSkim: ((Double?) -> Void)?
    var onSelect: ((Double) -> Void)?
    var onStep: ((Int) -> Void)?
    /// The number of slots or their size changed.
    var onLayoutChange: (() -> Void)?

    private static let thumbHeight: CGFloat = 54
    private static let spacing: CGFloat = 4
    private static let labelHeight: CGFloat = 14
    private static let bottomInset: CGFloat = 6

    private var hovered: Int?
    private var scrollRemainder: CGFloat = 0
    private var dragRemainder: CGFloat = 0
    private var lastDragX: CGFloat?
    private var lastSlotCount = 0

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var slotWidth: CGFloat { min(max(Self.thumbHeight * aspectRatio, 40), 120).rounded() }

    /// An odd number of slots, so one slot is in the middle.
    var slotCount: Int {
        let fit = Int((bounds.width - 16 + Self.spacing) / (slotWidth + Self.spacing))
        return min(max(fit % 2 == 1 ? fit : fit - 1, 3), 31)
    }

    /// The thumbnail size in pixels.
    var thumbnailSize: CGSize {
        let scale = window?.backingScaleFactor ?? 2
        return CGSize(width: slotWidth * scale, height: Self.thumbHeight * scale)
    }

    /// Stop skimming until the pointer moves again.
    func clearHover() {
        hovered = nil
        needsDisplay = true
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if slotCount != lastSlotCount { layoutChanged() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layoutChanged()
    }

    private func layoutChanged() {
        lastSlotCount = slotCount
        needsDisplay = true
        onLayoutChange?()
    }

    private func thumbRect(_ slot: Int) -> NSRect {
        let width = slotWidth
        let total = CGFloat(slotCount) * (width + Self.spacing) - Self.spacing
        let x = ((bounds.width - total) / 2).rounded() + CGFloat(slot) * (width + Self.spacing)
        return NSRect(x: x, y: Self.bottomInset + Self.labelHeight + 4, width: width, height: Self.thumbHeight)
    }

    private func slot(at point: NSPoint) -> Int? {
        (0..<min(slotCount, slots.count)).first { i in
            let rect = thumbRect(i)
            return point.x >= rect.minX - Self.spacing / 2 && point.x < rect.maxX + Self.spacing / 2
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.08, alpha: 1).setFill()
        bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let middle = slotCount / 2
        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        func label(_ i: Int) -> (text: String, attributes: [NSAttributedString.Key: Any], rect: NSRect)? {
            guard i < slots.count, let slot = slots[i] else { return nil }
            var text = slot.number.map(String.init) ?? String(format: "%.3f", slot.time)
            if i == middle, slot.number != nil, let frameCount { text += " of \(frameCount)" }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: labelFont,
                .foregroundColor: isMark(slot.time) ? NSColor.systemYellow
                    : i == middle ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]
            let size = text.size(withAttributes: attributes)
            let rect = NSRect(x: thumbRect(i).midX - size.width / 2, y: Self.bottomInset, width: size.width, height: size.height)
            return (text, attributes, rect)
        }
        // The middle label can be wider than its slot. Labels that it covers are not drawn.
        let middleLabel = label(middle)

        for (i, slot) in slots.enumerated() {
            guard let slot else { continue }
            let rect = thumbRect(i)

            if isMarked(slot.time) {
                NSColor.systemYellow.withAlphaComponent(0.85).setFill()
                NSRect(x: rect.minX - Self.spacing / 2, y: rect.minY - 4, width: rect.width + Self.spacing, height: 2).fill()
            }

            NSColor(white: 0.18, alpha: 1).setFill()
            rect.fill()
            if let image = slot.image {
                context.interpolationQuality = .high
                context.draw(image, in: fit(image, in: rect))
            }
            if isOutsideRange(slot.time) {
                NSColor.black.withAlphaComponent(0.55).setFill()
                rect.fill(using: .sourceOver)
            }

            if slot.changed {
                // A tick over the left edge: the picture changes between this frame and the one before.
                NSColor.systemOrange.setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX - 1, y: rect.maxY + 4, width: 10, height: 4),
                             xRadius: 2, yRadius: 2).fill()
            }

            if i == middle {
                NSColor.controlAccentColor.setStroke()
                let border = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
                border.lineWidth = 2
                border.stroke()
            } else if i == hovered {
                NSColor.white.withAlphaComponent(0.7).setStroke()
                NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5)).stroke()
            }

            // Drawn after the border, so the bracket shows on the current frame too.
            NSColor.systemYellow.setFill()
            if let start = marks.in, abs(slot.time - start) < 0.0005 { bracket(around: rect, opening: true).fill() }
            if let end = marks.out, abs(slot.time - end) < 0.0005 { bracket(around: rect, opening: false).fill() }

            if let label = i == middle ? middleLabel : label(i),
               i == middle || !label.rect.insetBy(dx: -4, dy: 0).intersects(middleLabel?.rect ?? .zero) {
                label.text.draw(at: label.rect.origin, withAttributes: label.attributes)
            }
        }
    }

    private func isMarked(_ time: Double) -> Bool {
        switch marks {
        case let (start?, end?): return time >= start - 0.0005 && time <= end + 0.0005
        case let (start?, nil): return abs(time - start) < 0.0005
        case let (nil, end?): return abs(time - end) < 0.0005
        case (nil, nil): return false
        }
    }

    private func isMark(_ time: Double) -> Bool {
        [marks.in, marks.out].contains { $0.map { abs(time - $0) < 0.0005 } ?? false }
    }

    /// Frames outside the marked range are dimmed, once both marks are set.
    private func isOutsideRange(_ time: Double) -> Bool {
        guard let start = marks.in, let end = marks.out else { return false }
        return time < start - 0.0005 || time > end + 0.0005
    }

    /// A "[" bracket on the left edge of the in frame, or a "]" bracket on the right edge of the out frame.
    private func bracket(around rect: NSRect, opening: Bool) -> NSBezierPath {
        let stem: CGFloat = 3, foot: CGFloat = 12, overhang: CGFloat = 3
        let stemX = opening ? rect.minX - stem : rect.maxX
        let footX = opening ? stemX : rect.maxX + stem - foot
        let bottom = rect.minY - overhang, height = rect.height + 2 * overhang
        let path = NSBezierPath(rect: NSRect(x: stemX, y: bottom, width: stem, height: height))
        path.append(NSBezierPath(rect: NSRect(x: footX, y: bottom, width: foot, height: stem)))
        path.append(NSBezierPath(rect: NSRect(x: footX, y: bottom + height - stem, width: foot, height: stem)))
        return path
    }

    private func fit(_ image: CGImage, in rect: NSRect) -> NSRect {
        let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    // MARK: - Pointer input

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        guard lastDragX == nil, let i = slot(at: convert(event.locationInWindow, from: nil)), i != hovered,
              let slot = slots[i] else { return }
        hovered = i
        needsDisplay = true
        onSkim?(slot.time)
    }

    override func mouseExited(with event: NSEvent) {
        guard lastDragX == nil else { return }
        clearHover()
        onSkim?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastDragX = point.x
        dragRemainder = 0
        clearHover()
        if let i = slot(at: point), let slot = slots[i] {
            onSelect?(slot.time)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let i = slot(at: convert(event.locationInWindow, from: nil)), let slot = slots[i] else { return nil }
        return FrameMenu.make(time: slot.time, frame: slot.number)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let lastDragX else { return }
        let x = convert(event.locationInWindow, from: nil).x
        self.lastDragX = x
        // Move the strip with the pointer: a drag to the left brings later frames to the middle.
        dragRemainder += x - lastDragX
        let pitch = slotWidth + Self.spacing
        let steps = Int(dragRemainder / pitch)
        guard steps != 0 else { return }
        dragRemainder -= CGFloat(steps) * pitch
        onStep?(-steps)
    }

    override func mouseUp(with event: NSEvent) {
        lastDragX = nil
    }

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began { scrollRemainder = 0 }
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        // A trackpad sends many small deltas. A wheel sends one line per notch, and one notch is one frame.
        scrollRemainder += abs(dx) > abs(dy) ? dx : dy
        let perFrame: CGFloat = event.hasPreciseScrollingDeltas ? 8 : 1
        let steps = Int(scrollRemainder / perFrame)
        guard steps != 0 else { return }
        scrollRemainder -= CGFloat(steps) * perFrame
        clearHover()
        // Content that moves left or up brings later frames to the middle.
        onStep?(-steps)
    }
}
