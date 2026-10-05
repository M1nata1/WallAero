import SwiftUI
import WallpaperCore

struct SettingsView: View {
    /// Window content height; the form scrolls when its sections need more.
    var height: CGFloat = 720

    @EnvironmentObject private var preferences: Preferences
    @EnvironmentObject private var library: WallpaperLibrary
    @State private var opensAtLogin = LaunchAtLogin.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("Playback") {
                Picker("Scaling", selection: $preferences.scaling) {
                    ForEach(ScalingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("Speed", selection: $preferences.playbackRate) {
                    ForEach(Preferences.playbackRates, id: \.self) { rate in
                        Text(Self.title(forRate: rate)).tag(rate)
                    }
                }
                Toggle("Play sound", isOn: $preferences.playsSound)
                Slider(value: $preferences.volume, in: 0...1) {
                    Text("Volume")
                } minimumValueLabel: {
                    Image(systemName: "speaker.fill")
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3.fill")
                }
                .disabled(!preferences.playsSound)
            }

            Section("Energy") {
                Toggle("Pause when windows cover the desktop", isOn: $preferences.pauseWhenCovered)
                Toggle("Pause on battery power", isOn: $preferences.pauseOnBattery)
                Toggle("Pause in Low Power Mode", isOn: $preferences.pauseInLowPowerMode)
            }

            CursorSettingsSection()

            Section("General") {
                Toggle("Open at login", isOn: $opensAtLogin)
                    .onChange(of: opensAtLogin) { enabled in
                        updateLoginItem(enabled)
                    }
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("Use the first frame as the macOS wallpaper", isOn: $preferences.setsSystemWallpaper)
                LabeledContent("Library folder") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.open(library.rootURL)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: height)
    }

    private func updateLoginItem(_ enabled: Bool) {
        guard enabled != LaunchAtLogin.isEnabled else { return }
        do {
            try LaunchAtLogin.setEnabled(enabled)
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
            // Put the switch back; the guard above stops the resulting onChange from looping.
            opensAtLogin = LaunchAtLogin.isEnabled
        }
    }

    private static func title(forRate rate: Double) -> String {
        if rate == 1 {
            return NSLocalizedString("Normal", comment: "Playback speed 1×")
        }
        return String(format: "%g×", rate)
    }
}
