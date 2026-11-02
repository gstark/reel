import AppKit

/// Puts grabbed frames on the clipboard.
///
/// Each frame is one clipboard item with a file URL and PNG data. Finder pastes
/// the files. Chat and design apps paste the images. The files stay in
/// ~/Library/Caches so a later paste still works. Folders older than one day are removed.
enum FrameClipboard {
    static func makeFolder() throws -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Reel")
            .appendingPathComponent("Frames")
        removeOldFolders(in: root)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let folder = root.appendingPathComponent(formatter.string(from: Date()))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func copy(_ urls: [URL]) {
        let items = urls.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            if let png = try? Data(contentsOf: url) {
                item.setData(png, forType: .png)
            }
            return item
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }

    private static func removeOldFolders(in root: URL) {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < cutoff {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }
}
