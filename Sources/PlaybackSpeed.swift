import Foundation

/// The speed for normal playback. Reel remembers it between launches.
enum PlaybackSpeed {
    static let steps: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4]
    private static let key = "playbackSpeed"

    /// The last speed the user chose. A value that is not a step gives normal speed.
    static var saved: Double {
        get {
            let value = UserDefaults.standard.double(forKey: key)
            return steps.contains(value) ? value : 1
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func faster(than speed: Double) -> Double? { steps.first { $0 > speed } }
    static func slower(than speed: Double) -> Double? { steps.last { $0 < speed } }

    static func label(_ speed: Double) -> String { String(format: "%g×", speed) }
}
