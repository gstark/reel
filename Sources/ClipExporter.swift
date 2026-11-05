import AVFoundation

/// Writes a part of a video to a new file without re-encoding it.
///
/// The passthrough export copies the samples, so it is fast and keeps the quality. It works for
/// files that AVFoundation can open (MP4 and MOV), the same files that have a frame index.
final class ClipExporter {
    private let session: AVAssetExportSession
    private var timer: Timer?

    /// `range` is in asset time (seconds).
    init?(source: URL, range: ClosedRange<Double>, destination: URL) {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return nil }
        let wanted: AVFileType = switch destination.pathExtension.lowercased() {
        case "mov": .mov
        case "m4v": .m4v
        default: .mp4
        }
        guard let fileType = session.supportedFileTypes.contains(wanted) ? wanted : session.supportedFileTypes.first else { return nil }
        session.outputFileType = fileType
        session.outputURL = destination
        session.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600_000),
                                        end: CMTime(seconds: range.upperBound, preferredTimescale: 600_000))
        self.session = session
    }

    /// Calls `progress` on the main thread with 0...1 while the export runs, and `completion`
    /// when it ends. The error is nil after a success, and `CancellationError` after `cancel()`.
    func start(progress: @escaping (Double) -> Void, completion: @escaping (Error?) -> Void) {
        if let url = session.outputURL { try? FileManager.default.removeItem(at: url) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            progress(Double(session.progress))
        }
        session.exportAsynchronously {
            // This closure keeps the exporter alive until the export ends.
            DispatchQueue.main.async {
                self.timer?.invalidate()
                self.timer = nil
                let session = self.session
                switch session.status {
                case .completed: completion(nil)
                case .cancelled: completion(CancellationError())
                default: completion(session.error ?? CocoaError(.fileWriteUnknown))
                }
            }
        }
    }

    func cancel() {
        session.cancelExport()
    }
}
