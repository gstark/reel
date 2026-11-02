import AppKit

/// A standard titled window. A double-click on the title bar always toggles
/// between "fill the screen" and the previous frame, whatever the system
/// title bar double-click setting is.
final class PlayerWindow: NSWindow {
    private var restoreFrame: NSRect?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 2, isInTitleBar(event) {
            toggleMaximize(nil)
            return
        }
        super.sendEvent(event)
    }

    @objc func toggleMaximize(_ sender: Any?) {
        guard !styleMask.contains(.fullScreen), let screen else { return }
        let target = screen.visibleFrame
        if isMaximized(on: screen), let restoreFrame {
            self.restoreFrame = nil
            setFrame(restoreFrame, display: true, animate: true)
        } else {
            restoreFrame = frame
            setFrame(target, display: true, animate: true)
        }
    }

    private func isMaximized(on screen: NSScreen) -> Bool {
        let target = screen.visibleFrame
        return abs(frame.minX - target.minX) < 2 && abs(frame.minY - target.minY) < 2
            && abs(frame.width - target.width) < 2 && abs(frame.height - target.height) < 2
    }

    private func isInTitleBar(_ event: NSEvent) -> Bool {
        guard !styleMask.contains(.fullScreen), let contentView, let frameView = contentView.superview else { return false }
        let point = event.locationInWindow
        guard point.y > contentView.frame.maxY else { return false }
        return !(frameView.hitTest(point) is NSButton)
    }
}
