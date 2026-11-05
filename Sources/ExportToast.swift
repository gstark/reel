import AppKit

/// The announcement after an export: a dark glass panel at the bottom of the video.
///
/// It shows a picture of the result, so the user sees the first exported frame. A clip shows
/// one frame. PNG frames show a stack. It rises into place, stays for a few seconds, and fades.
/// The pointer over it keeps it open.
final class ExportToast: NSView {
    static let gap: CGFloat = 16
    private static let visibleSeconds = 6.0
    private static let thumbHeight: CGFloat = 44

    /// Removes the toast from its superview. The owner clears its reference here.
    var onDismiss: (() -> Void)?

    private let reveal: [URL]
    private let thumbnail = ThumbnailView()
    private var dismissWork: DispatchWorkItem?
    private var isDismissing = false

    init(title: String, detail: String, isStack: Bool, reveal: [URL]) {
        self.reveal = reveal
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true

        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .withinWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 12
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 0.5
        glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        thumbnail.isStack = isStack
        thumbnail.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let showButton = NSButton(title: "Show in Finder", target: self, action: #selector(showInFinder))
        showButton.bezelStyle = .push
        showButton.controlSize = .small
        showButton.setContentHuggingPriority(.required, for: .horizontal)

        let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!,
                                   target: self, action: #selector(close))
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        closeButton.toolTip = "Close"

        let row = NSStackView(views: [thumbnail, text, showButton, closeButton])
        row.spacing = 12
        row.setCustomSpacing(8, after: showButton)
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false

        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        glass.addSubview(row)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            row.topAnchor.constraint(equalTo: glass.topAnchor),
            row.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            thumbnail.heightAnchor.constraint(equalToConstant: Self.thumbHeight + ThumbnailView.margin * 2),
            thumbnail.widthAnchor.constraint(equalToConstant: Self.thumbHeight * 16 / 9 + ThumbnailView.margin * 2),
            text.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])

        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(title). \(detail)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The first exported frame. It can arrive after the toast opens.
    var image: CGImage? {
        get { thumbnail.image }
        set { thumbnail.image = newValue }
    }

    // MARK: - Showing and dismissing

    /// Call after the toast is in its superview and has its frame.
    func present() {
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: accessibilityLabel() ?? "", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer {
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = -10
            rise.toValue = 0
            rise.duration = 0.3
            rise.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            layer.add(rise, forKey: "rise")
        }
        scheduleDismiss()
    }

    private func scheduleDismiss() {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleSeconds, execute: work)
    }

    @objc func close() {
        guard !isDismissing else { return }
        isDismissing = true
        dismissWork?.cancel()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.removeFromSuperview()
            self?.onDismiss?()
        }
    }

    @objc private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(reveal)
        close()
    }

    // MARK: - Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { dismissWork?.cancel() }
    override func mouseExited(with event: NSEvent) { if !isDismissing { scheduleDismiss() } }
    /// Clicks on the toast do not reach the video under it.
    override func mouseDown(with event: NSEvent) {}
}

/// The first exported frame with a yellow check on its corner. As a stack, two offset
/// frame outlines sit behind it, for a set of PNG files.
private final class ThumbnailView: NSView {
    static let margin: CGFloat = 7

    var image: CGImage? { didSet { needsDisplay = true } }
    var isStack = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let area = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        var frame = area
        if let image, image.height > 0 {
            // Fit the image's own aspect ratio, centered.
            let aspect = CGFloat(image.width) / CGFloat(image.height)
            let width = min(area.width, area.height * aspect), height = width / aspect
            frame = NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
        }
        if isStack {
            frame = frame.offsetBy(dx: -3, dy: -3)
            for step in [2, 1] {
                let back = frame.offsetBy(dx: CGFloat(step) * 3, dy: CGFloat(step) * 3)
                NSColor(white: 0.32 - CGFloat(step) * 0.06, alpha: 1).setFill()
                NSBezierPath(roundedRect: back, xRadius: 3, yRadius: 3).fill()
            }
        }

        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
        clip.addClip()
        NSColor(white: 0.2, alpha: 1).setFill()
        frame.fill()
        if let image, let context = NSGraphicsContext.current?.cgContext {
            context.interpolationQuality = .high
            context.draw(image, in: frame)
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.15).setStroke()
        clip.lineWidth = 0.5
        clip.stroke()

        // The check: yellow, like the marks and the progress fill.
        let badge = NSRect(x: frame.maxX - 11, y: frame.minY - 3, width: 14, height: 14)
        NSColor.systemYellow.setFill()
        NSBezierPath(ovalIn: badge).fill()
        let check = NSBezierPath()
        check.move(to: NSPoint(x: badge.minX + 3.8, y: badge.midY + 0.2))
        check.line(to: NSPoint(x: badge.minX + 6.0, y: badge.minY + 4.4))
        check.line(to: NSPoint(x: badge.maxX - 3.4, y: badge.maxY - 4.2))
        check.lineWidth = 1.8
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        NSColor.black.withAlphaComponent(0.85).setStroke()
        check.stroke()
    }
}
