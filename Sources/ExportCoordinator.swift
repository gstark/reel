import AppKit
import AVFoundation

/// Exports the part from the in mark to the out mark, as a clip or as PNG frames, to this Mac
/// or to a folder on an SSH server.
///
/// An export to a server first writes to a temporary folder, then sends the result through ssh.
/// The scrubber band fills once for the export and once for the upload. After a good upload,
/// the temporary copy is deleted. After a failed upload, it stays, so the export is not lost.
final class ExportCoordinator {
    private let url: URL
    private let player: MPVPlayer
    private let navigator: FrameNavigator
    private let controlBar: ControlBar
    private let window: () -> NSWindow?
    private let frameIndex: () -> FrameIndex?
    private let showStatus: (String?) -> Void
    private let showToast: (ExportToast, CGImage?) -> Void

    /// Stops the step that runs. nil when no export runs.
    private var cancelStep: (() -> Void)?
    /// Holds the remote panel while it is on screen.
    private var remotePanel: RemoteSavePanel?

    init(url: URL, player: MPVPlayer, navigator: FrameNavigator, controlBar: ControlBar,
         window: @escaping () -> NSWindow?, frameIndex: @escaping () -> FrameIndex?,
         showStatus: @escaping (String?) -> Void, showToast: @escaping (ExportToast, CGImage?) -> Void) {
        self.url = url
        self.player = player
        self.navigator = navigator
        self.controlBar = controlBar
        self.window = window
        self.frameIndex = frameIndex
        self.showStatus = showStatus
        self.showToast = showToast
    }

    var isRunning: Bool { cancelStep != nil }
    var canExport: Bool { frameIndex() != nil && navigator.markedRange != nil }

    func cancel() { cancelStep?() }

    private var baseName: String { url.deletingPathExtension().lastPathComponent }

    /// The marked frames: one-based numbers, the in and out frame times, and the time range in mpv time.
    private struct Marked {
        let index: FrameIndex
        let first: Int
        let last: Int
        let range: ClosedRange<Double>
        let start: Double
        let end: Double
        var count: Int { last - first + 1 }
    }

    private func markedFrames() -> Marked? {
        guard let index = frameIndex(), let range = navigator.markedRange,
              let start = navigator.inPoint, let end = navigator.outPoint else { return nil }
        return Marked(index: index, first: index.frame(at: start) + 1, last: index.frame(at: end) + 1,
                      range: range, start: start, end: end)
    }

    // MARK: - Clip

    /// Save the part from the in frame to the end of the out frame as a new video file.
    func exportClip() {
        guard !isRunning, let marked = markedFrames() else { return }
        player.pause()
        let name = "\(baseName) frames \(marked.first)-\(marked.last).\(url.pathExtension)"
        let message = "Export frames \(marked.first) to \(marked.last) as a new file."
        // AVFoundation time differs from mpv time by the frame index offset.
        let range = marked.range.lowerBound + marked.index.assetOffset...marked.range.upperBound + marked.index.assetOffset
        let detail = "\(marked.count) frames, \(String(format: "%.2f", range.upperBound - range.lowerBound)) s"

        switch ExportMemory.destination {
        case .local: chooseLocalClip(name: name, message: message, range: range, detail: detail)
        case .remote(let target): chooseRemoteClip(target, name: name, message: message, range: range, detail: detail)
        }
    }

    private func chooseLocalClip(name: String, message: String, range: ClosedRange<Double>, detail: String) {
        guard let window = window() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.directoryURL = url.deletingLastPathComponent()
        panel.message = message
        panel.prompt = "Export"
        let picker = DestinationPicker(selected: .local)
        var switchTo: SSHTarget?
        picker.onChange = { destination in
            guard case .remote(let target) = destination else { return }
            switchTo = target
            panel.cancel(nil)
        }
        let form = PanelForm(centered: true)
        form.addRow(label: "Save to:", control: picker)
        form.fitForPanel()
        panel.accessoryView = form
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if let target = switchTo {
                ExportMemory.destination = .remote(target)
                return chooseRemoteClip(target, name: panel.nameFieldStringValue, message: message, range: range, detail: detail)
            }
            guard response == .OK, let destination = panel.url else { return }
            ExportMemory.destination = .local
            writeClip(range, to: destination) { [weak self] error in
                guard let self, finishStep(error) else { return }
                let folder = destination.deletingLastPathComponent().lastPathComponent
                let toast = ExportToast(title: "Exported \(destination.lastPathComponent)", detail: "\(detail), in \(folder)",
                                        isStack: false, actionTitle: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
                showToast(toast, nil)
                Task { @MainActor [weak toast] in toast?.image = await Self.firstFrame(of: destination) }
            }
        }
    }

    private func chooseRemoteClip(_ target: SSHTarget, name: String, message: String, range: ClosedRange<Double>, detail: String) {
        guard let window = window() else { return }
        let nameView = FileNameView(name: name)
        let panel = RemoteSavePanel(target: target, message: message, prompt: "Export", accessory: nameView)
        remotePanel = panel
        panel.begin(for: window) { [weak self] result in
            guard let self else { return }
            remotePanel = nil
            switch result {
            case .cancel:
                break
            case .local:
                chooseLocalClip(name: nameView.name, message: message, range: range, detail: detail)
            case let .export(connection, folder, files):
                let fileName = nameView.name
                let remote = RemoteSavePanel.join(folder, fileName)
                confirmReplace(files.contains(fileName) ? 1 : 0, in: folder, connection: connection) { [weak self] in
                    self?.uploadClip(range, named: fileName, to: remote, connection: connection, detail: detail)
                }
            }
        }
    }

    private func uploadClip(_ range: ClosedRange<Double>, named name: String, to remote: String,
                            connection: SSHConnection, detail: String) {
        guard let temporary = Self.makeTemporaryFolder() else { return }
        let file = temporary.appendingPathComponent(name)
        writeClip(range, to: file) { [weak self] error in
            guard let self, finishStep(error, keeping: temporary, closing: connection) else { return }
            Task { @MainActor [weak self] in
                // Read the picture before the upload deletes the temporary copy.
                let image = await Self.firstFrame(of: file)
                self?.upload(.file(file, remote), temporary: temporary, connection: connection) { [weak self] in
                    self?.showToast(ExportToast(title: "Uploaded \(name)", detail: "\(detail), to \(connection.target.name):\(remote)",
                                                isStack: false, actionTitle: "Copy Path") {
                        Self.copy("\(connection.target.address):\(remote)")
                    }, image)
                }
            }
        }
    }

    /// Writes the clip with AVFoundation, with progress on the scrubber band.
    private func writeClip(_ range: ClosedRange<Double>, to destination: URL, then: @escaping (Error?) -> Void) {
        guard let exporter = ClipExporter(source: url, range: range, destination: destination) else {
            then(SSHError(errorDescription: "This file type cannot be exported."))
            return
        }
        cancelStep = exporter.cancel
        controlBar.setExportProgress(0)
        showStatus("Exporting 0%…")
        exporter.start { [weak self] progress in
            self?.controlBar.setExportProgress(progress)
            self?.showStatus("Exporting \(Int(progress * 100))%…")
        } completion: { error in
            then(error)
        }
    }

    // MARK: - PNG frames

    /// Save each frame from the in frame to the out frame as a PNG file in a folder.
    /// The file name is a prefix and the frame number. The number has as many digits as
    /// the frame count of the video, with leading zeros, so all names have the same length.
    func exportFrames() {
        guard !isRunning, markedFrames() != nil else { return }
        player.pause()
        switch ExportMemory.destination {
        case .local: chooseLocalFrames(prefix: "\(baseName)-")
        case .remote(let target): chooseRemoteFrames(target, prefix: "\(baseName)-")
        }
    }

    private func framesMessage(_ marked: Marked) -> String {
        "Choose a folder for \(marked.count) PNG files, frames \(marked.first) to \(marked.last)."
    }

    private func fileNames(prefix: String, index: FrameIndex) -> (Double) -> String {
        let digits = String(index.count).count
        return { time in prefix + FramePrefixView.number(index.frame(at: time) + 1, digits: digits) + ".png" }
    }

    private func chooseLocalFrames(prefix: String) {
        guard let window = window(), let marked = markedFrames() else { return }
        let prefixView = FramePrefixView(prefix: prefix, exampleFrame: marked.first,
                                         digits: String(marked.index.count).count, centered: true)
        let picker = DestinationPicker(selected: .local)
        prefixView.insertRow(at: 0, label: "Save to:", control: picker)
        prefixView.fitForPanel()

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = url.deletingLastPathComponent()
        panel.message = framesMessage(marked)
        panel.prompt = "Export"
        panel.accessoryView = prefixView
        panel.isAccessoryViewDisclosed = true
        var switchTo: SSHTarget?
        picker.onChange = { destination in
            guard case .remote(let target) = destination else { return }
            switchTo = target
            panel.cancel(nil)
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if let target = switchTo {
                ExportMemory.destination = .remote(target)
                return chooseRemoteFrames(target, prefix: prefixView.prefix)
            }
            guard response == .OK, let folder = panel.url else { return }
            ExportMemory.destination = .local
            let fileName = fileNames(prefix: prefixView.prefix, index: marked.index)
            let existing = (marked.first...marked.last).filter { frame in
                FileManager.default.fileExists(atPath: folder.appendingPathComponent(fileName(marked.index.times[frame - 1])).path)
            }.count
            confirmReplace(existing, in: folder.lastPathComponent, connection: nil) { [weak self] in
                self?.writeFrames(marked, into: folder, fileName: fileName) { [weak self] result in
                    guard let self, case .success(let frames) = result else { return }
                    let first = frames.first?.url
                    showToast(ExportToast(title: Self.framesTitle(frames.count, "Exported"),
                                          detail: "\(first?.lastPathComponent ?? "") and on, in \(folder.lastPathComponent)",
                                          isStack: frames.count > 1, actionTitle: "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([first ?? folder])
                    }, first.flatMap(Self.thumbnail))
                }
            }
        }
    }

    private func chooseRemoteFrames(_ target: SSHTarget, prefix: String) {
        guard let window = window(), let marked = markedFrames() else { return }
        let prefixView = FramePrefixView(prefix: prefix, exampleFrame: marked.first,
                                         digits: String(marked.index.count).count, centered: false)
        let panel = RemoteSavePanel(target: target, message: framesMessage(marked), prompt: "Export", accessory: prefixView)
        remotePanel = panel
        panel.begin(for: window) { [weak self] result in
            guard let self else { return }
            remotePanel = nil
            switch result {
            case .cancel:
                break
            case .local:
                chooseLocalFrames(prefix: prefixView.prefix)
            case let .export(connection, folder, files):
                let fileName = fileNames(prefix: prefixView.prefix, index: marked.index)
                let existing = (marked.first...marked.last).filter { files.contains(fileName(marked.index.times[$0 - 1])) }.count
                confirmReplace(existing, in: folder, connection: connection) { [weak self] in
                    self?.uploadFrames(marked, into: folder, fileName: fileName, connection: connection)
                }
            }
        }
    }

    private func uploadFrames(_ marked: Marked,
                              into folder: String, fileName: @escaping (Double) -> String, connection: SSHConnection) {
        guard let temporary = Self.makeTemporaryFolder() else { return }
        writeFrames(marked, into: temporary, fileName: fileName, keeping: temporary, closing: connection) { [weak self] result in
            guard let self, case .success(let frames) = result else { return }
            let image = frames.first.flatMap { Self.thumbnail(of: $0.url) }
            let first = frames.first?.url.lastPathComponent ?? ""
            upload(.files(frames.map(\.url), folder), temporary: temporary, connection: connection) { [weak self] in
                self?.showToast(ExportToast(title: Self.framesTitle(frames.count, "Uploaded"),
                                            detail: "\(first) and on, to \(connection.target.name):\(folder)",
                                            isStack: frames.count > 1, actionTitle: "Copy Path") {
                    Self.copy("\(connection.target.address):\(folder)/")
                }, image)
            }
        }
    }

    /// Saves the frames with the hidden mpv instance, with progress on the scrubber band.
    /// `then` gets the result only after a success. A failure is shown here.
    private func writeFrames(_ marked: Marked,
                             into folder: URL, fileName: @escaping (Double) -> String,
                             keeping temporary: URL? = nil, closing connection: SSHConnection? = nil,
                             then: @escaping (Result<[FrameGrabber.Frame], Error>) -> Void) {
        let count = marked.count
        let stop = StopFlag()
        cancelStep = stop.set
        controlBar.setExportProgress(0)
        showStatus("Exporting frame 0 of \(count)…")
        let source = url, start = marked.start, end = marked.end
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try FrameGrabber.grab(source, at: start, before: 0, after: .max, through: end, into: folder,
                                      fileName: fileName) { saved in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !stop.isSet else { return }
                        controlBar.setExportProgress(Double(saved) / Double(count))
                        showStatus("Exporting frame \(saved) of \(count)…")
                    }
                    return !stop.isSet
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success:
                    guard finishStep(nil, keeping: nil, closing: nil) else { return }
                case .failure(let error):
                    guard finishStep(error, keeping: temporary, closing: connection) else { return }
                }
                then(result)
            }
        }
    }

    // MARK: - Upload

    private enum Payload {
        case file(URL, String)
        case files([URL], String)
    }

    /// Sends the export to the server, then deletes the temporary copy and closes the connection.
    private func upload(_ payload: Payload, temporary: URL, connection: SSHConnection, then: @escaping () -> Void) {
        let stop = StopFlag()
        cancelStep = stop.set
        let server = connection.target.name
        controlBar.setExportProgress(0)
        showStatus("Uploading 0% to \(server)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var last = -1
            let progress: (Double) -> Bool = { fraction in
                let percent = Int(fraction * 100)
                if percent != last {
                    last = percent
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !stop.isSet else { return }
                        controlBar.setExportProgress(fraction)
                        showStatus("Uploading \(percent)% to \(server)…")
                    }
                }
                return !stop.isSet
            }
            let result = Result {
                switch payload {
                case let .file(file, remote): try connection.upload(file, to: remote, progress: progress)
                case let .files(files, folder): try connection.upload(files, to: folder, progress: progress)
                }
            }
            if case .success = result { try? FileManager.default.removeItem(at: temporary) }
            connection.close()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success:
                    finishStep(nil)
                    then()
                case .failure(let error):
                    finishStep(error, keeping: temporary, upload: true)
                }
            }
        }
    }

    // MARK: - Shared steps

    /// Ends a step. A failure or a cancel shows here and returns false.
    /// A temporary folder is kept after an upload failure, and deleted after any other failure.
    @discardableResult
    private func finishStep(_ error: Error?, keeping temporary: URL? = nil, closing connection: SSHConnection? = nil,
                            upload: Bool = false) -> Bool {
        cancelStep = nil
        controlBar.setExportProgress(nil)
        guard let error else {
            showStatus(nil)
            return true
        }
        if let connection { DispatchQueue.global().async { connection.close() } }
        if let temporary, !upload { try? FileManager.default.removeItem(at: temporary) }
        if error is CancellationError {
            showStatus(upload ? "Upload canceled" : "Export canceled")
            if let temporary, upload { try? FileManager.default.removeItem(at: temporary) }
        } else if upload, let temporary {
            showError("Cannot upload", "\(error.localizedDescription)\n\nThe export is saved on this Mac.", keep: temporary)
        } else {
            showError("Cannot export", error.localizedDescription, keep: nil)
        }
        return false
    }

    /// Asks before an export writes over files. `count` is the number of files it replaces.
    private func confirmReplace(_ count: Int, in folder: String, connection: SSHConnection?, then: @escaping () -> Void) {
        guard count > 0, let window = window() else { return then() }
        // A panel can still be closing. Show the question after it.
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = count == 1 ? "Replace 1 file?" : "Replace \(count) files?"
            alert.informativeText = "\((folder as NSString).lastPathComponent) already has files with these names."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    then()
                } else if let connection {
                    DispatchQueue.global().async { connection.close() }
                }
            }
        }
    }

    private func showError(_ title: String, _ message: String, keep folder: URL?) {
        guard let window = window() else { return }
        showStatus(nil)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if folder != nil { alert.addButton(withTitle: "Show in Finder") }
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn, let folder {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
        }
    }

    // MARK: - Helpers

    private static func framesTitle(_ count: Int, _ verb: String) -> String {
        count == 1 ? "\(verb) 1 frame" : "\(verb) \(count) frames"
    }

    private static func makeTemporaryFolder() -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Reel Export \(UUID().uuidString)")
        return (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil ? folder : nil
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The first frame of a video file, read back from the file.
    @MainActor
    private static func firstFrame(of file: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: .zero).image
    }

    /// A small image of a PNG file, for the toast.
    private static func thumbnail(of url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 320,
        ] as CFDictionary)
    }
}

/// The file name field of the remote panel, for a clip.
final class FileNameView: PanelForm {
    private let field: NSTextField

    /// The typed name. A "/" would make a folder, so it becomes "-".
    var name: String {
        field.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
    }

    init(name: String) {
        field = NSTextField(string: name)
        super.init(centered: false)
        field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        addRow(label: "Name:", control: field)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
