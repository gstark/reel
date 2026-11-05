import AppKit

/// The context menu that copies the time code and the frame number of one frame as text.
enum CopyTimeMenu {
    /// `frame` is one-based. Without it, the menu only copies the time code.
    static func make(time: Double, frame: Int?) -> NSMenu {
        let timecode = ControlBar.format(time, milliseconds: true)
        let menu = NSMenu()
        menu.addItem(item("Copy Time Code (\(timecode))", timecode))
        if let frame {
            menu.addItem(item("Copy Frame Number (\(frame))", String(frame)))
            menu.addItem(item("Copy Time Code and Frame Number", "\(timecode) (frame \(frame))"))
        }
        return menu
    }

    private static func item(_ title: String, _ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(Target.copy(_:)), keyEquivalent: "")
        item.target = Target.shared
        item.representedObject = text
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
