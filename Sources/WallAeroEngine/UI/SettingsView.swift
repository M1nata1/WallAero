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
                MusicSettingsRows()
                if #available(macOS 14.2, *) {
                    Toggle("Wallpapers react to sound", isOn: $preferences.reactsToSound)
                }
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

/// The rows for the user's own music: the folder, and once it is chosen, the playlist and order.
/// With music in the folder it plays in place of the videos' sound.
private struct MusicSettingsRows: View {
    @EnvironmentObject private var preferences: Preferences
    @EnvironmentObject private var manager: WallpaperManager

    var body: some View {
        LabeledContent("Music folder") {
            HStack(spacing: 8) {
                if let path = preferences.musicFolderPath {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button(preferences.musicFolderPath == nil ? "Choose Folder…" : "Change…", action: chooseFolder)
                if preferences.musicFolderPath != nil {
                    Button("Remove") {
                        preferences.musicFolderPath = nil
                        preferences.musicPlaylist = nil
                    }
                }
            }
        }
        if let playlists = manager.musicFolder?.playlists, !playlists.isEmpty {
            Picker("Playlist", selection: $preferences.musicPlaylist) {
                Text("All Music").tag(String?.none)
                ForEach(playlists) { playlist in
                    Text(playlist.name).tag(String?.some(playlist.name))
                }
            }
            .disabled(!preferences.playsSound)
        }
        if preferences.musicFolderPath != nil {
            Toggle("Shuffle", isOn: $preferences.shufflesMusic)
                .disabled(!preferences.playsSound)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("Choose", comment: "Open panel button")
        panel.message = NSLocalizedString("Choose a folder with music. Its subfolders and .m3u files become playlists.", comment: "Open panel")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let folder = await Task.detached(priority: .userInitiated) { MusicFolder.scan(url) }.value
            guard !folder.allTracks.isEmpty else {
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("No music was found in that folder.", comment: "Music folder alert")
                alert.informativeText = NSLocalizedString("MP3, M4A, AAC, WAV, AIFF and FLAC files are supported.", comment: "Music folder alert")
                alert.runModal()
                return
            }
            preferences.musicPlaylist = nil
            preferences.musicFolderPath = url.path
            // Whoever picks music wants to hear it.
            preferences.playsSound = true
        }
    }
}
