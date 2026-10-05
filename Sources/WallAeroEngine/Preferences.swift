import Combine
import Foundation

enum ScalingMode: String, CaseIterable, Identifiable {
    /// Covers the whole screen, cropping the edges if the aspect ratio differs.
    case fill
    /// Shows the whole picture with black bars.
    case fit
    case stretch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fill: return NSLocalizedString("Fill Screen", comment: "Scaling mode")
        case .fit: return NSLocalizedString("Fit to Screen", comment: "Scaling mode")
        case .stretch: return NSLocalizedString("Stretch", comment: "Scaling mode")
        }
    }
}

@MainActor
final class Preferences: ObservableObject {
    static let playbackRates: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2]

    private enum Key {
        static let scaling = "scaling"
        static let playbackRate = "playbackRate"
        static let playsSound = "playsSound"
        static let volume = "volume"
        static let pauseWhenCovered = "pauseWhenCovered"
        static let pauseOnBattery = "pauseOnBattery"
        static let pauseInLowPowerMode = "pauseInLowPowerMode"
        static let setsSystemWallpaper = "setsSystemWallpaper"
    }

    private let defaults: UserDefaults

    @Published var scaling: ScalingMode {
        didSet { defaults.set(scaling.rawValue, forKey: Key.scaling) }
    }
    @Published var playbackRate: Double {
        didSet { defaults.set(playbackRate, forKey: Key.playbackRate) }
    }
    @Published var playsSound: Bool {
        didSet { defaults.set(playsSound, forKey: Key.playsSound) }
    }
    @Published var volume: Double {
        didSet { defaults.set(volume, forKey: Key.volume) }
    }
    /// Stop decoding while windows or a full-screen app hide the desktop.
    @Published var pauseWhenCovered: Bool {
        didSet { defaults.set(pauseWhenCovered, forKey: Key.pauseWhenCovered) }
    }
    @Published var pauseOnBattery: Bool {
        didSet { defaults.set(pauseOnBattery, forKey: Key.pauseOnBattery) }
    }
    @Published var pauseInLowPowerMode: Bool {
        didSet { defaults.set(pauseInLowPowerMode, forKey: Key.pauseInLowPowerMode) }
    }
    /// Also set a still frame as the regular macOS wallpaper, which shows on the lock screen,
    /// in Mission Control and whenever the app is not running.
    @Published var setsSystemWallpaper: Bool {
        didSet { defaults.set(setsSystemWallpaper, forKey: Key.setsSystemWallpaper) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.scaling: ScalingMode.fill.rawValue,
            Key.playbackRate: 1.0,
            Key.playsSound: false,
            Key.volume: 0.5,
            Key.pauseWhenCovered: true,
            Key.pauseOnBattery: false,
            Key.pauseInLowPowerMode: true,
            Key.setsSystemWallpaper: false,
        ])
        scaling = ScalingMode(rawValue: defaults.string(forKey: Key.scaling) ?? "") ?? .fill
        playbackRate = defaults.double(forKey: Key.playbackRate)
        playsSound = defaults.bool(forKey: Key.playsSound)
        volume = defaults.double(forKey: Key.volume)
        pauseWhenCovered = defaults.bool(forKey: Key.pauseWhenCovered)
        pauseOnBattery = defaults.bool(forKey: Key.pauseOnBattery)
        pauseInLowPowerMode = defaults.bool(forKey: Key.pauseInLowPowerMode)
        setsSystemWallpaper = defaults.bool(forKey: Key.setsSystemWallpaper)
    }
}
