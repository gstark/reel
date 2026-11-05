import AppKit

/// Where an export goes: this Mac, or a folder on an SSH server.
enum ExportDestination: Equatable {
    case local
    case remote(SSHTarget)
}

/// The export choices that Reel remembers: the last destination, the last folder on each
/// server, and the servers the user typed.
enum ExportMemory {
    private static let defaults = UserDefaults.standard
    private static let destinationKey = "exportDestination"
    private static let foldersKey = "exportRemoteFolders"
    private static let typedKey = "exportTypedServers"

    static var destination: ExportDestination {
        get {
            guard let data = defaults.data(forKey: destinationKey),
                  let target = try? JSONDecoder().decode(SSHTarget.self, from: data) else { return .local }
            return .remote(target)
        }
        set {
            switch newValue {
            case .local: defaults.removeObject(forKey: destinationKey)
            case .remote(let target): defaults.set(try? JSONEncoder().encode(target), forKey: destinationKey)
            }
        }
    }

    static func folder(on target: SSHTarget) -> String? {
        (defaults.dictionary(forKey: foldersKey) as? [String: String])?[target.name]
    }

    static func setFolder(_ folder: String, on target: SSHTarget) {
        var folders = defaults.dictionary(forKey: foldersKey) as? [String: String] ?? [:]
        folders[target.name] = folder
        defaults.set(folders, forKey: foldersKey)
    }

    /// Servers from "Other Server…", newest first.
    static var typedServers: [SSHTarget] {
        get {
            guard let data = defaults.data(forKey: typedKey) else { return [] }
            return (try? JSONDecoder().decode([SSHTarget].self, from: data)) ?? []
        }
        set { defaults.set(try? JSONEncoder().encode(Array(newValue.prefix(5))), forKey: typedKey) }
    }

    static func remember(typed target: SSHTarget) {
        typedServers = [target] + typedServers.filter { $0 != target }
    }
}

/// The "Save to" menu, without its label: This Mac, the hosts from ~/.ssh/config, the typed servers, and
/// "Other Server…". Picking a server reports it. "Other Server…" asks for one first.
final class DestinationPicker: NSView {
    var onChange: ((ExportDestination) -> Void)?

    private let popup = NSPopUpButton()
    private var destinations: [ExportDestination?] = []
    private var current: ExportDestination

    init(selected: ExportDestination) {
        current = selected
        super.init(frame: .zero)
        popup.target = self
        popup.action = #selector(picked)
        popup.translatesAutoresizingMaskIntoConstraints = false
        addSubview(popup)
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: trailingAnchor),
            popup.topAnchor.constraint(equalTo: topAnchor),
            popup.bottomAnchor.constraint(equalTo: bottomAnchor),
            popup.widthAnchor.constraint(equalToConstant: 300),
        ])
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func rebuild() {
        popup.removeAllItems()
        destinations = []
        func add(_ title: String, _ destination: ExportDestination?, symbol: String? = nil) {
            popup.addItem(withTitle: title)
            if let symbol {
                popup.lastItem?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            destinations.append(destination)
        }
        func separator() {
            popup.menu?.addItem(.separator())
            destinations.append(nil)
        }

        add("This Mac", .local, symbol: "laptopcomputer")
        let configured = SSHConfig.hosts().map { SSHTarget(host: $0) }
        var servers = configured + ExportMemory.typedServers.filter { !configured.contains($0) }
        if case .remote(let target) = current, !servers.contains(target) { servers.append(target) }
        if !servers.isEmpty { separator() }
        for server in servers { add(server.name, .remote(server), symbol: "server.rack") }
        separator()
        add("Other Server…", nil)

        popup.selectItem(at: destinations.firstIndex(of: current) ?? 0)
    }

    @objc private func picked() {
        let index = popup.indexOfSelectedItem
        if let destination = destinations[index] {
            guard destination != current else { return }
            current = destination
            onChange?(destination)
            return
        }
        // "Other Server…": go back to the current choice until the user enters a server.
        popup.selectItem(at: destinations.firstIndex(of: current) ?? 0)
        guard let window = window else { return }
        OtherServerSheet.ask(in: window) { [weak self] target in
            guard let self, let target else { return }
            ExportMemory.remember(typed: target)
            current = .remote(target)
            rebuild()
            onChange?(current)
        }
    }
}

/// Asks for a server that is not in ~/.ssh/config: host, user, port, and a key file.
enum OtherServerSheet {
    static func ask(in window: NSWindow, completion: @escaping (SSHTarget?) -> Void) {
        let host = field("example.com or 203.0.113.7")
        let user = field(NSUserName())
        let port = field("22")
        let key = field("Default keys and ssh-agent")
        let choose = NSButton(title: "Choose…", target: nil, action: nil)
        let chooser = KeyChooser(field: key)
        choose.target = chooser
        choose.action = #selector(KeyChooser.choose)

        let grid = NSGridView(views: [
            [label("Host:"), host],
            [label("User:"), user],
            [label("Port:"), port],
            [label("Key file:"), key, choose],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 2), verticalRange: NSRange(location: 0, length: 1))
        grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 2), verticalRange: NSRange(location: 1, length: 1))
        grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 2), verticalRange: NSRange(location: 2, length: 1))
        [host, user, port].forEach { $0.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        key.widthAnchor.constraint(equalToConstant: 210).isActive = true
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)

        let alert = NSAlert()
        alert.messageText = "Connect to a server"
        alert.informativeText = "Reel logs in with your SSH keys and ssh-agent. It does not ask for passwords."
        alert.accessoryView = grid
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = host
        alert.beginSheetModal(for: window) { response in
            withExtendedLifetime(chooser) {}
            let name = host.stringValue.trimmingCharacters(in: .whitespaces)
            guard response == .alertFirstButtonReturn, !name.isEmpty else { return completion(nil) }
            let userName = user.stringValue.trimmingCharacters(in: .whitespaces)
            let keyFile = key.stringValue.trimmingCharacters(in: .whitespaces)
            completion(SSHTarget(host: name,
                                 user: userName.isEmpty ? nil : userName,
                                 port: Int(port.stringValue.trimmingCharacters(in: .whitespaces)),
                                 identityFile: keyFile.isEmpty ? nil : keyFile))
        }
    }

    private static func field(_ placeholder: String) -> NSTextField {
        let field = NSTextField(string: "")
        field.placeholderString = placeholder
        return field
    }

    private static func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    /// Opens a file panel for the key file, in ~/.ssh.
    private final class KeyChooser: NSObject {
        let field: NSTextField
        init(field: NSTextField) { self.field = field }

        @objc func choose() {
            let panel = NSOpenPanel()
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
            panel.showsHiddenFiles = true
            panel.message = "Choose the private key for this server."
            if panel.runModal() == .OK, let url = panel.url {
                field.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
            }
        }
    }
}
