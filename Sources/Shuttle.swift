import AppKit

/// The J, K, and L keys, as in video editors.
///
/// - L plays forward at the playback speed. Each press doubles the speed. J does the same backward.
/// - K stops.
/// - With K held, a tap on J or L steps one frame. A held J or L plays at quarter speed until it is released.
///
/// Holding a key needs key-up events, so the window controller sends the raw key events here.
final class Shuttle {
    private let player: MPVPlayer
    private let step: (Int) -> Void

    /// True while K is held. The frame strip stays open during slow playback.
    private(set) var isHoldingStop = false
    /// The J or L key that started slow playback, or that waits for it.
    private var slowKey: String?
    private var slowTimer: Timer?

    private static let maximumSpeed = 16.0
    private static let slowSpeed = 0.25

    init(player: MPVPlayer, step: @escaping (Int) -> Void) {
        self.player = player
        self.step = step
    }

    /// Returns true when the event was a J, K, or L key without modifiers.
    func handle(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased(), ["j", "k", "l"].contains(key)
        else { return false }
        if event.type == .keyDown {
            if !event.isARepeat { keyDown(key) }
        } else {
            keyUp(key)
        }
        return true
    }

    func playForward() { shuttle(forward: true) }
    func playBackward() { shuttle(forward: false) }
    func stop() { player.stop() }

    private func shuttle(forward: Bool) {
        let isRunning = !player.isPaused && player.isForward == forward
        player.play(forward: forward, speed: isRunning ? min(player.speed * 2, Self.maximumSpeed) : player.playbackSpeed)
    }

    private func keyDown(_ key: String) {
        if key == "k" {
            isHoldingStop = true
            stop()
            return
        }
        let forward = key == "l"
        guard isHoldingStop else {
            shuttle(forward: forward)
            return
        }
        step(forward ? 1 : -1)
        slowKey = key
        slowTimer?.invalidate()
        slowTimer = .scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            guard let self, isHoldingStop, slowKey == key else { return }
            player.play(forward: forward, speed: Self.slowSpeed)
        }
    }

    private func keyUp(_ key: String) {
        if key == "k" { isHoldingStop = false }
        guard let slowKey, key == "k" || key == slowKey else { return }
        self.slowKey = nil
        slowTimer?.invalidate()
        slowTimer = nil
        stop()
    }
}
