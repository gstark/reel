import AppKit

/// The menu bar. Playback items carry the keyboard shortcuts, so they work
/// from anywhere in the player window and show up in the menu.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(playbackMenu()))
        main.addItem(submenu(windowMenu()))
        return main
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Reel")
        menu.addItem(withTitle: "About Reel", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Reel", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Reel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "Open…", action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o")
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Export In to Out…", action: #selector(PlayerWindowController.exportMarkedRange(_:)), keyEquivalent: "e")
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Copy Frame", #selector(PlayerWindowController.copy(_:)), "c", [.command]))
        menu.addItem(item("Copy Frames Around Pause", #selector(PlayerWindowController.copyFramesAroundPause(_:)), "c", [.command, .shift]))
        menu.addItem(item("Copy Frames from In to Out", #selector(PlayerWindowController.copyMarkedFrames(_:)), "c", [.command, .option]))
        return menu
    }

    private static func playbackMenu() -> NSMenu {
        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        let menu = NSMenu(title: "Playback")
        menu.addItem(item("Play/Pause", #selector(PlayerWindowController.togglePlayPause(_:)), " ", []))
        // The window controller reads J, K, and L as raw key events, so it can see a held key.
        // These items show the keys and work from the menu.
        menu.addItem(item("Play Backward", #selector(PlayerWindowController.playBackward(_:)), "j", []))
        menu.addItem(item("Stop", #selector(PlayerWindowController.stopPlayback(_:)), "k", []))
        menu.addItem(item("Play Forward", #selector(PlayerWindowController.playForward(_:)), "l", []))
        menu.addItem(.separator())
        menu.addItem(item("Back 5 Seconds", #selector(PlayerWindowController.skipBackward(_:)), left, []))
        menu.addItem(item("Forward 5 Seconds", #selector(PlayerWindowController.skipForward(_:)), right, []))
        menu.addItem(item("Back 30 Seconds", #selector(PlayerWindowController.skipBackwardLong(_:)), left, [.shift]))
        menu.addItem(item("Forward 30 Seconds", #selector(PlayerWindowController.skipForwardLong(_:)), right, [.shift]))
        menu.addItem(.separator())
        menu.addItem(item("Previous Frame", #selector(PlayerWindowController.previousFrame(_:)), ",", []))
        menu.addItem(item("Next Frame", #selector(PlayerWindowController.nextFrame(_:)), ".", []))
        menu.addItem(item("Previous Change", #selector(PlayerWindowController.previousChange(_:)), ",", [.option]))
        menu.addItem(item("Next Change", #selector(PlayerWindowController.nextChange(_:)), ".", [.option]))
        menu.addItem(.separator())
        menu.addItem(item("Set In", #selector(PlayerWindowController.markIn(_:)), "i", []))
        menu.addItem(item("Set Out", #selector(PlayerWindowController.markOut(_:)), "o", []))
        menu.addItem(item("Go to In", #selector(PlayerWindowController.goToIn(_:)), "i", [.shift]))
        menu.addItem(item("Go to Out", #selector(PlayerWindowController.goToOut(_:)), "o", [.shift]))
        menu.addItem(item("Clear In and Out", #selector(PlayerWindowController.clearMarks(_:)), "x", [.option]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Maximize", action: #selector(PlayerWindow.toggleMaximize(_:)), keyEquivalent: "")
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        NSApp.windowsMenu = menu
        return menu
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
