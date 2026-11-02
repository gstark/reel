import AppKit

/// Frame-level navigation: the frame strip, frame steps, skimming, the change search, and in and out marks.
///
/// With a frame index (MP4 and MOV), each step is an exact seek to the frame start time. Steps
/// accumulate before mpv shows the frame, so fast scrolls do not lose steps. Without an index,
/// steps use mpv frame stepping, and the strip comes from a hidden mpv instance.
final class FrameNavigator {
    let strip = FrameStripView()

    var index: FrameIndex? {
        didSet {
            reader = FrameReader(url: url, index: index)
            cache = [:]
            decoded = []
            marksChanged()
            refresh()
        }
    }

    /// True while the strip is on screen.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive {
                refresh()
            } else {
                skimOrigin = nil
                strip.clearHover()
            }
        }
    }

    private(set) var inPoint: Double?
    private(set) var outPoint: Double?

    /// Shows a short status text, or removes it (nil).
    var onStatus: ((String?) -> Void)?
    var onMarksChange: (() -> Void)?

    private let url: URL
    private let player: MPVPlayer
    private var reader: FrameReader

    /// Strip thumbnails by frame number, when a frame index exists.
    private var cache: [Int: Thumbnail] = [:]
    /// Consecutive frames around the current frame, when no frame index exists.
    private var decoded: [Thumbnail] = []
    private var decodedReachesEnd = false
    private var isLoading = false
    private var refreshScheduled = false

    /// The frame of the last seek that mpv does not show yet.
    private var pending: (frame: Int, date: Date)?
    /// The time to go back to when skimming stops.
    private var skimOrigin: Double?
    private var searchTask: Task<Void, Never>?

    init(url: URL, player: MPVPlayer) {
        self.url = url
        self.player = player
        reader = FrameReader(url: url, index: nil)
        strip.onSkim = { [weak self] in self?.skim($0) }
        strip.onSelect = { [weak self] in self?.select($0) }
        strip.onStep = { [weak self] in self?.stripStep($0) }
        strip.onLayoutChange = { [weak self] in self?.stripLayoutChanged() }
    }

    private var thumbnailSize = CGSize.zero

    private func stripLayoutChanged() {
        // A new slot count only needs more frames. A new slot size needs new thumbnails.
        if strip.thumbnailSize != thumbnailSize {
            thumbnailSize = strip.thumbnailSize
            cache = [:]
            decoded = []
        }
        refresh()
    }

    // MARK: - Current frame

    /// The frame on screen, or the frame of a seek that mpv does not show yet.
    var currentFrame: Int? {
        guard let index else { return nil }
        if let pending, Date().timeIntervalSince(pending.date) < 1 { return pending.frame }
        return index.frame(at: player.position)
    }

    /// The start time of the current frame.
    var currentTime: Double {
        if let index, let frame = currentFrame { return index.times[frame] }
        return player.position
    }

    /// The duration of one frame near the current frame.
    var frameDuration: Double {
        if let index, let frame = currentFrame, index.count > 1 {
            let next = min(frame + 1, index.count - 1)
            let duration = index.times[next] - index.times[next - 1]
            if duration > 0 { return duration }
        }
        let fps = player.double("container-fps") ?? 0
        return fps > 0 ? 1 / fps : 1.0 / 30
    }

    /// Call when mpv reports a new position or state.
    func playerStateChanged() {
        if let index, let pending, index.frame(at: player.position) == pending.frame {
            self.pending = nil
        }
        refresh()
    }

    // MARK: - Steps

    /// A frame step from the keyboard or the control bar. It starts at the frame on screen,
    /// also while skimming.
    func step(by count: Int) {
        let base = currentTime
        skimOrigin = nil
        step(by: count, from: base)
    }

    /// Scroll and drag steps on the strip start at the frame the strip is centered on.
    private func stripStep(_ count: Int) {
        let base = skimOrigin ?? currentTime
        let wasSkimming = skimOrigin != nil
        skimOrigin = nil
        if wasSkimming && index == nil { player.seek(to: base, exact: true) }
        step(by: count, from: base)
    }

    private func step(by count: Int, from base: Double) {
        player.pause()
        if let index {
            go(to: index.frame(at: base) + count)
        } else {
            for _ in 0..<abs(count) { player.stepFrame(forward: count > 0) }
        }
    }

    /// Go to a frame, and stay there when skimming stops.
    func select(_ time: Double) {
        skimOrigin = nil
        player.pause()
        if let index {
            go(to: index.frame(at: time))
        } else {
            player.seek(to: time, exact: true)
        }
    }

    private func go(to frame: Int) {
        guard let index else { return }
        let frame = min(max(frame, 0), index.count - 1)
        pending = (frame, Date())
        player.seek(to: index.times[frame], exact: true)
        refresh()
    }

    private func skim(_ time: Double?) {
        if let time {
            if skimOrigin == nil { skimOrigin = currentTime }
            player.seek(to: time, exact: true)
        } else if let origin = skimOrigin {
            skimOrigin = nil
            player.seek(to: origin, exact: true)
        }
    }

    // MARK: - Strip

    /// Rebuild the strip on the next pass of the run loop. Many calls in one pass rebuild it once.
    func refresh() {
        guard isActive, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.rebuild(load: true)
        }
    }

    private func rebuild(load: Bool) {
        guard isActive else { return }
        // While skimming, the strip stays on the frame that skimming started from.
        let center = skimOrigin ?? currentTime
        if let index {
            rebuildIndexed(index, center: index.frame(at: center), load: load)
        } else {
            rebuildDecoded(center: center, load: load)
        }
    }

    private func rebuildIndexed(_ index: FrameIndex, center: Int, load: Bool) {
        let half = strip.slotCount / 2
        strip.slots = (center - half...center + half).map { frame in
            guard index.times.indices.contains(frame) else { return nil }
            let thumbnail = cache[frame]
            let changed = thumbnail.flatMap { thumbnail in cache[frame - 1].map(thumbnail.differs) } ?? false
            return .init(time: index.times[frame], number: frame + 1, image: thumbnail?.image, changed: changed)
        }

        // One extra frame on the left gives the first slot a frame to compare with.
        let wanted = max(center - half - 1, 0)...min(center + half, index.count - 1)
        guard load, !isLoading, let first = wanted.first(where: { cache[$0] == nil }),
              let last = wanted.last(where: { cache[$0] == nil }) else { return }
        isLoading = true
        let stream = reader.frames(from: index.times[first], count: last - first + 1, fitting: strip.thumbnailSize)
        Task { @MainActor [weak self] in
            do {
                for try await thumbnail in stream {
                    self?.cache[index.frame(at: thumbnail.time)] = thumbnail
                    self?.rebuild(load: false)
                }
            } catch {}
            guard let self else { return }
            if cache.count > 2000 {
                cache = cache.filter { abs($0.key - center) < 500 }
            }
            isLoading = false
            // Load what the strip needs now. The position can have moved during the load.
            rebuild(load: true)
        }
    }

    private func rebuildDecoded(center: Double, load: Bool) {
        let half = strip.slotCount / 2
        let anchor = decoded.lastIndex { $0.time <= center + 0.0005 }
        if let anchor, decoded[anchor].time > center - frameDuration {
            strip.slots = (anchor - half...anchor + half).map { k in
                guard decoded.indices.contains(k) else { return nil }
                let changed = k > 0 && decoded[k].differs(from: decoded[k - 1])
                return .init(time: decoded[k].time, number: nil, image: decoded[k].image, changed: changed)
            }
            let startCovered = anchor - half - 1 >= 0 || (decoded.first?.time ?? 1) < frameDuration / 2
            let endCovered = anchor + half < decoded.count || decodedReachesEnd
            if startCovered && endCovered { return }
        }
        guard load, !isLoading else { return }

        // mpv has no frame index here, so start a few frames early with the estimated frame duration.
        isLoading = true
        let count = 2 * half + 8
        let start = max(center - Double(half + 4) * frameDuration, 0)
        let stream = reader.frames(from: start, count: count, fitting: strip.thumbnailSize)
        Task { @MainActor [weak self] in
            var frames: [Thumbnail] = []
            do {
                for try await thumbnail in stream { frames.append(thumbnail) }
            } catch {}
            guard let self else { return }
            decoded = frames
            decodedReachesEnd = frames.count < count
            isLoading = false
            // Load again only when the position moved during this load.
            rebuild(load: abs(center - (skimOrigin ?? currentTime)) > 0.0005)
        }
    }

    // MARK: - Change search

    /// Go to the next frame that differs from the frame before it, or to the previous such frame.
    /// Screen recordings have long runs of identical frames, and this skips them.
    func findChange(forward: Bool) {
        searchTask?.cancel()
        let start = currentTime
        skimOrigin = nil
        player.pause()
        onStatus?(forward ? "Looking for the next change…" : "Looking for the previous change…")
        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let target = forward ? await nextChange(after: start) : await previousChange(before: start)
            guard !Task.isCancelled else { return }
            if let target {
                onStatus?(nil)
                select(target)
            } else {
                onStatus?(forward ? "No change after this frame" : "No change before this frame")
            }
        }
    }

    private static let searchChunk = 240
    private static let searchSize = CGSize(width: 192, height: 192)

    private func nextChange(after time: Double) async -> Double? {
        var from = time
        while !Task.isCancelled {
            let frames = await read(from: from, count: Self.searchChunk + 1)
            guard frames.count > 1 else { return nil }
            for k in 1..<frames.count where frames[k].differs(from: frames[k - 1]) {
                return frames[k].time
            }
            if frames.count <= Self.searchChunk { return nil }
            from = frames[frames.count - 1].time
        }
        return nil
    }

    private func previousChange(before time: Double) async -> Double? {
        // Look at frames that start before `end`. The first pass leaves out the current frame.
        var end = time - 0.0005
        while !Task.isCancelled {
            let from: Double
            if let index {
                from = index.times[max(index.frame(at: end) - Self.searchChunk, 0)]
            } else {
                from = max(end - Double(Self.searchChunk) * frameDuration, 0)
            }
            let frames = await read(from: from, count: Self.searchChunk + 10).filter { $0.time < end }
            guard let first = frames.first else { return nil }
            for k in stride(from: frames.count - 1, through: 1, by: -1) where frames[k].differs(from: frames[k - 1]) {
                return frames[k].time
            }
            // The first frame of the file counts as a change.
            if from <= (index?.times.first ?? 0) + 0.0005 { return first.time }
            // The next pass ends with `first`, so it compares `first` with the frame before it.
            end = first.time + 0.0005
        }
        return nil
    }

    private func read(from time: Double, count: Int) async -> [Thumbnail] {
        var frames: [Thumbnail] = []
        do {
            for try await frame in reader.frames(from: time, count: count, fitting: Self.searchSize) {
                frames.append(frame)
            }
        } catch {}
        return frames
    }

    // MARK: - In and out marks

    func markIn() {
        let time = currentTime
        inPoint = time
        if let outPoint, outPoint < time { self.outPoint = nil }
        marksChanged()
    }

    func markOut() {
        let time = currentTime
        outPoint = time
        if let inPoint, inPoint > time { self.inPoint = nil }
        marksChanged()
    }

    func clearMarks() {
        inPoint = nil
        outPoint = nil
        marksChanged()
    }

    /// The number of frames from the in frame to the out frame, both included.
    var markedFrameCount: Int? {
        guard let inPoint, let outPoint else { return nil }
        if let index { return index.frame(at: outPoint) - index.frame(at: inPoint) + 1 }
        return Int(((outPoint - inPoint) / frameDuration).rounded()) + 1
    }

    private func marksChanged() {
        strip.marks = (inPoint, outPoint)
        // Playback loops from the in frame to the end of the out frame.
        if let inPoint, let outPoint {
            player.setLoop(inPoint...max(endOfFrame(at: outPoint) - 0.0005, inPoint))
        } else {
            player.setLoop(nil)
        }
        onMarksChange?()
    }

    private func endOfFrame(at time: Double) -> Double {
        if let index {
            let next = index.frame(at: time) + 1
            return next < index.count ? index.times[next] : max(player.duration, time)
        }
        return time + frameDuration
    }
}
