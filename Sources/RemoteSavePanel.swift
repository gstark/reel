import AppKit

/// A sheet that picks a folder on an SSH server, like a save panel for a remote disk.
///
/// It lists the folders of the current folder. A double-click opens a folder, Up goes to the
/// parent, and the path field takes a typed path. Files show dimmed, so the user sees what is
/// there already. The "Save to" menu switches to another server or back to this Mac.
final class RemoteSavePanel: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    enum Result {
        /// The caller owns the connection now, and closes it.
        case export(SSHConnection, folder: String, files: Set<String>)
        case local
        case cancel
    }

    private var connection: SSHConnection
    private var listing: SSHConnection.Listing?
    private var loadTask: Task<Void, Never>?
    private var completion: ((Result) -> Void)?

    private let picker: DestinationPicker
    private let pathField = NSTextField(string: "")
    private let upButton = NSButton()
    private let newFolderButton = NSButton(title: "New Folder", target: nil, action: nil)
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let exportButton: NSButton

    /// The panel adds its "Save to:" row to the top of `accessory`, so the rows line up.
    init(target: SSHTarget, message: String, prompt: String, accessory: PanelForm) {
        connection = SSHConnection(target: target)
        picker = DestinationPicker(selected: .remote(target))
        exportButton = NSButton(title: prompt, target: nil, action: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.minSize = NSSize(width: 460, height: 380)
        super.init(window: window)
        build(message: message, accessory: accessory)
        picker.onChange = { [weak self] in self?.destinationChanged($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func begin(for parent: NSWindow, completion: @escaping (Result) -> Void) {
        self.completion = completion
        guard let window else { return }
        parent.beginSheet(window)
        load(ExportMemory.folder(on: connection.target), fallBackHome: true)
    }

    // MARK: - Layout

    private func build(message: String, accessory: PanelForm) {
        guard let content = window?.contentView else { return }

        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.textColor = .secondaryLabelColor

        upButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Enclosing folder")
        upButton.bezelStyle = .texturedRounded
        upButton.toolTip = "Enclosing folder"
        upButton.target = self
        upButton.action = #selector(goUp)
        pathField.delegate = self
        pathField.target = self
        pathField.action = #selector(pathEntered)
        pathField.placeholderString = "~/path/to/folder"
        pathField.lineBreakMode = .byTruncatingHead
        // Bottom left, with the shortcut of the standard save panel.
        newFolderButton.target = self
        newFolderButton.action = #selector(newFolder)
        newFolderButton.keyEquivalent = "n"
        newFolderButton.keyEquivalentModifierMask = [.command, .shift]
        newFolderButton.toolTip = "New folder in the open folder (⇧⌘N)"
        let pathRow = NSStackView(views: [upButton, pathField])
        pathRow.spacing = 6

        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let statusRow = NSStackView(views: [spinner, status])
        statusRow.spacing = 6

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        exportButton.target = self
        exportButton.action = #selector(export)
        exportButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [newFolderButton, statusRow, NSView(), cancel, exportButton])
        buttons.spacing = 12
        statusRow.setContentHuggingPriority(.defaultLow, for: .horizontal)

        accessory.insertRow(at: 0, label: "Save to:", control: picker)
        let stack = NSStackView(views: [messageLabel, accessory, pathRow, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(6, after: pathRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        for view in [messageLabel, pathRow, scroll, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        accessory.setContentHuggingPriority(.required, for: .vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
    }

    // MARK: - Loading

    /// Lists a folder. When `fallBackHome` is true and the folder fails, it lists the home folder.
    private func load(_ path: String?, fallBackHome: Bool = false) {
        loadTask?.cancel()
        setBusy("Connecting to \(connection.target.name)…")
        let connection = connection
        loadTask = Task { @MainActor [weak self] in
            do {
                let listing = try await connection.list(path)
                guard !Task.isCancelled, let self, self.connection === connection else { return }
                show(listing)
            } catch {
                guard !Task.isCancelled, let self, self.connection === connection else { return }
                if fallBackHome, path != nil {
                    load(nil)
                } else {
                    showError(error.localizedDescription)
                }
            }
        }
    }

    private func show(_ listing: SSHConnection.Listing) {
        self.listing = listing
        pathField.stringValue = listing.path
        table.reloadData()
        table.scrollRowToVisible(0)
        let count = visibleFolders.count
        setReady(count == 0 ? "No folders here." : count == 1 ? "1 folder" : "\(count) folders")
    }

    private func setBusy(_ text: String) {
        spinner.startAnimation(nil)
        status.stringValue = text
        status.textColor = .secondaryLabelColor
        [exportButton, upButton, newFolderButton].forEach { $0.isEnabled = false }
    }

    private func setReady(_ text: String) {
        spinner.stopAnimation(nil)
        status.stringValue = text
        status.textColor = .secondaryLabelColor
        [exportButton, upButton, newFolderButton].forEach { $0.isEnabled = true }
        upButton.isEnabled = listing?.path != "/"
    }

    private func showError(_ text: String) {
        spinner.stopAnimation(nil)
        status.stringValue = text
        status.textColor = .systemRed
        exportButton.isEnabled = false
        upButton.isEnabled = listing != nil
        newFolderButton.isEnabled = false
    }

    // MARK: - Table

    /// Hidden files and folders are left out, as in Finder.
    private var visibleFolders: [String] { listing?.folders.filter { !$0.hasPrefix(".") } ?? [] }
    private var visibleFiles: [String] { listing?.files.filter { !$0.hasPrefix(".") } ?? [] }

    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleFolders.count + visibleFiles.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let isFolder = row < visibleFolders.count
        let name = isFolder ? visibleFolders[row] : visibleFiles[row - visibleFolders.count]
        let cell = tableView.makeView(withIdentifier: .init("cell"), owner: nil) as? NSTableCellView ?? makeCell()
        cell.textField?.stringValue = name
        cell.textField?.textColor = isFolder ? .labelColor : .tertiaryLabelColor
        cell.imageView?.image = NSImage(systemSymbolName: isFolder ? "folder.fill" : "doc", accessibilityDescription: nil)
        cell.imageView?.contentTintColor = isFolder ? .controlAccentColor : .tertiaryLabelColor
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        row < visibleFolders.count
    }

    private func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = .init("cell")
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        let row = NSStackView(views: [image, text])
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(row)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
        ])
        return cell
    }

    // MARK: - Actions

    @objc private func openSelected() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard let listing, row >= 0, row < visibleFolders.count else { return }
        load(Self.join(listing.path, visibleFolders[row]))
    }

    @objc private func goUp() {
        guard let listing, listing.path != "/" else { return }
        load((listing.path as NSString).deletingLastPathComponent)
    }

    @objc private func pathEntered() {
        let path = pathField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, path != listing?.path else { return }
        load(path)
    }

    @objc private func newFolder() {
        guard let listing, let window else { return }
        let field = NSTextField(string: "")
        field.placeholderString = "Folder name"
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        let alert = NSAlert()
        alert.messageText = "New folder in \(listing.path)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard let self, response == .alertFirstButtonReturn, !name.isEmpty, !name.contains("/") else { return }
            let path = Self.join(listing.path, name)
            setBusy("Creating \(name)…")
            let connection = connection
            Task { @MainActor [weak self] in
                do {
                    try await connection.makeFolder(path)
                    self?.load(path)
                } catch {
                    self?.showError(error.localizedDescription)
                }
            }
        }
    }

    /// The export goes into the folder that is open. A selected folder does not count, as in a save panel.
    @objc private func export() {
        guard let listing else { return }
        ExportMemory.setFolder(listing.path, on: connection.target)
        ExportMemory.destination = .remote(connection.target)
        finish(.export(connection, folder: listing.path, files: Set(listing.files)))
    }

    @objc private func cancel() {
        connection.close()
        finish(.cancel)
    }

    private func destinationChanged(_ destination: ExportDestination) {
        switch destination {
        case .local:
            connection.close()
            ExportMemory.destination = .local
            finish(.local)
        case .remote(let target):
            let old = connection
            DispatchQueue.global().async { old.close() }
            connection = SSHConnection(target: target)
            listing = nil
            table.reloadData()
            pathField.stringValue = ""
            load(ExportMemory.folder(on: target), fallBackHome: true)
        }
    }

    private func finish(_ result: Result) {
        loadTask?.cancel()
        if let window { window.sheetParent?.endSheet(window) }
        completion?(result)
        completion = nil
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }
}
