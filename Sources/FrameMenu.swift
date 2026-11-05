import AppKit

/// The right-click menu of the scrubber and the frame strip, for one frame.
///
/// The copy items put the time code or the frame number on the clipboard as text.
/// The mark and export items go through the responder chain to the window controller,
/// which enables them. The mark items carry the frame time in `representedObject`.
enum FrameMenu {
    /// `frame` is one-based. Without it, the menu only copies the time code.
    static func make(time: Double, frame: Int?) -> NSMenu {
        let timecode = ControlBar.format(time, milliseconds: true)
        let menu = NSMenu()
        menu.addItem(copyItem("Copy Time Code (\(timecode))", timecode))
        if let frame {
            menu.addItem(copyItem("Copy Frame Number (\(frame))", String(frame)))
            menu.addItem(copyItem("Copy Time Code and Frame Number", "\(timecode) (frame \(frame))"))
        }

        menu.addItem(.separator())
        menu.addItem(markItem("Set In Here", #selector(PlayerWindowController.markIn(_:)), time))
        menu.addItem(markItem("Set Out Here", #selector(PlayerWindowController.markOut(_:)), time))
        menu.addItem(withTitle: "Clear In and Out", action: #selector(PlayerWindowController.clearMarks(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        // The window controller sets the title: "Export In to Out…" or "Cancel Export".
        menu.addItem(withTitle: "Export In to Out…", action: #selector(PlayerWindowController.exportMarkedRange(_:)), keyEquivalent: "")
        return menu
    }

    private static func copyItem(_ title: String, _ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(Target.copy(_:)), keyEquivalent: "")
        item.target = Target.shared
        item.representedObject = text
        return item
    }

    private static func markItem(_ title: String, _ action: Selector, _ time: Double) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.representedObject = time
        return item
    }

    private final class Target: NSObject {
        static let shared = Target()

        @objc func copy(_ item: NSMenuItem) {
            guard let text = item.representedObject as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
