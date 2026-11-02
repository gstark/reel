import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var players: [PlayerWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
    }

    /// AppKit calls this when the app launches (or is reopened) with no file to open.
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        openDocument(nil)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(open)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audiovisualContent]
        NSApp.activate()
        panel.begin { [weak self] response in
            guard let self else { return }
            if response == .OK {
                panel.urls.forEach(open)
            } else if players.isEmpty {
                NSApp.terminate(nil)
            }
        }
    }

    private func open(_ url: URL) {
        let player = PlayerWindowController(url: url) { [weak self] closed in
            self?.players.removeAll { $0 === closed }
        }
        players.append(player)
    }
}
