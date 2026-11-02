import AVFoundation

/// Presentation times of every video frame, so a time maps to an exact frame number.
///
/// Screen recordings have a variable frame rate, so `time × fps` drifts.
/// This reads the sample table only (no decoding). It works for files that
/// AVFoundation can open (MP4, MOV). For other files, `load` returns nil.
struct FrameIndex {
    /// Sorted frame start times in seconds.
    let times: [Double]

    var count: Int { times.count }

    /// The zero-based number of the frame shown at `time`.
    func frame(at time: Double) -> Int {
        // Last frame that starts at or before `time`. The tolerance absorbs rounding
        // between mpv and AVFoundation timestamps.
        var low = 0, high = times.count
        while low < high {
            let mid = (low + high) / 2
            if times[mid] <= time + 0.0005 { low = mid + 1 } else { high = mid }
        }
        return max(low - 1, 0)
    }

    static func load(_ url: URL) async -> FrameIndex? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              (try? await track.load(.canProvideSampleCursors)) == true,
              let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() else { return nil }

        // The cursor gives media time. The track's edit list maps media time to the
        // playback time that mpv reports. Files with B-frames (CleanShot H.264) start
        // their media time a few frames late, and the edit list moves them back to 0.
        let mappings = ((try? await track.load(.segments)) ?? []).filter { !$0.isEmpty }.map(\.timeMapping)
        func playbackTime(_ time: CMTime) -> Double? {
            guard !mappings.isEmpty else { return time.seconds }
            guard let mapping = mappings.first(where: { $0.source.containsTime(time) }) else { return nil }
            let scale = mapping.target.duration.seconds / mapping.source.duration.seconds
            return mapping.target.start.seconds + (time - mapping.source.start).seconds * scale
        }

        // The cursor walks the sample table without reading frame data, so this is fast.
        var times: [Double] = []
        repeat {
            let time = cursor.presentationTimeStamp
            if time.isNumeric, let playback = playbackTime(time) { times.append(playback) }
        } while cursor.stepInDecodeOrder(byCount: 1) == 1

        guard !times.isEmpty else { return nil }
        times.sort()

        // When the edit starts inside a frame, FFmpeg (and so mpv) moves the first
        // visible frame to the edit start. AVFoundation keeps the partial offset. Match FFmpeg.
        if let start = mappings.first?.target.start.seconds {
            let shift = start - times[0]
            times = times.map { $0 + shift }
        }
        return FrameIndex(times: times)
    }
}
