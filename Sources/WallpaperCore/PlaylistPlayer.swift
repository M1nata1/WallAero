import AVFoundation
import Combine

/// Plays a list of audio files one after another, around and around.
///
/// A file is opened only once playback is wanted, so while nothing plays the audio hardware is
/// left alone and the Mac can sleep.
@MainActor
public final class PlaylistPlayer: ObservableObject {
    /// The track that is playing, or will play once playback starts.
    @Published public private(set) var currentTrack: URL?

    public var volume: Float = 1 {
        didSet { player.volume = volume }
    }

    public var hasTracks: Bool { !queue.tracks.isEmpty }

    private let player = AVPlayer()
    private var queue = TrackQueue()
    private var wantsPlayback = false
    private var observers: [NSObjectProtocol] = []
    private var statusObserver: AnyCancellable?
    /// Files in a row that could not be played; stops the player going round a broken list forever.
    private var failuresInARow = 0

    public init() {
        player.actionAtItemEnd = .pause
    }

    /// Replaces the list. A track that is playing and is on the new list too carries on.
    public func setTracks(_ tracks: [URL], shuffled: Bool) {
        guard tracks != queue.tracks || shuffled != queue.shuffles else { return }
        let carriesOn = currentTrack.map(tracks.contains) ?? false
        queue = TrackQueue(tracks: tracks, shuffles: shuffled, startingWith: currentTrack)
        failuresInARow = 0
        if !carriesOn {
            start(queue.current)
        }
    }

    public func setPlaying(_ playing: Bool) {
        wantsPlayback = playing
        if playing {
            loadIfNeeded()
            player.play()
        } else {
            player.pause()
        }
    }

    public func skipToNext() {
        failuresInARow = 0
        start(queue.advance())
    }

    // MARK: - Playing a track

    /// Begins the track from its start, or just remembers it while playback is not wanted.
    private func start(_ track: URL?) {
        currentTrack = track
        unload()
        if wantsPlayback {
            loadIfNeeded()
            player.play()
        }
    }

    private func loadIfNeeded() {
        guard player.currentItem == nil, let track = currentTrack else { return }
        let item = AVPlayerItem(url: track)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.trackEnded(item, failed: false) }
            },
            center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.trackEnded(item, failed: true) }
            },
        ]
        // A file AVFoundation cannot open never starts, so it never "ends" either.
        statusObserver = item.publisher(for: \.status)
            .filter { $0 == .failed }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.trackEnded(item, failed: true) }
        player.volume = volume
        player.replaceCurrentItem(with: item)
    }

    private func unload() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        statusObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    private func trackEnded(_ item: AVPlayerItem, failed: Bool) {
        guard item === player.currentItem else { return } // a late notice about a track already left
        failuresInARow = failed ? failuresInARow + 1 : 0
        if failuresInARow >= queue.tracks.count {
            // Nothing on the list can be played.
            unload()
            return
        }
        start(queue.advance())
    }
}
