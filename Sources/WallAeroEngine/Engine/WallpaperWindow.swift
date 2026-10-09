import AppKit
import AVFoundation
import QuartzCore
import WallpaperCore

/// A borderless window at the desktop level: above the regular macOS wallpaper, below the
/// desktop icons and every app window, present on all Spaces and invisible to the mouse.
final class WallpaperWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        isRestorable = false
        isMovable = false
        animationBehavior = .none
        // Hiding the app (⌘H) must not take the wallpaper away.
        canHide = false
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws one wallpaper: an AVPlayerLayer for video, a plain layer for still pictures and a web
/// view, added only when needed, for scenes and other web wallpapers.
final class WallpaperView: NSView {
    private let playerLayer = AVPlayerLayer()
    private let imageLayer = CALayer()
    private(set) var webView: WebWallpaperView?
    /// Called once what was asked for can be seen: at once for a picture, with the first frame
    /// for a video, when the page has drawn for a web wallpaper.
    var onReady: (() -> Void)?
    private(set) var isReady = false
    private var firstFrame: NSKeyValueObservation?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var looperStatus: NSKeyValueObservation?

    private var videoURL: URL?
    private var loadTask: Task<Void, Never>?
    private var videoHasAudio = false
    private var playerHasAudio = false

    private var scaling = ScalingMode.fill
    private var position = 50.0
    private var mediaSize = CGSize.zero

    // Requested playback state, applied whenever a player becomes available.
    private var isPlaying = false
    private var rate: Float = 1
    private var isMuted = true
    private var volume: Float = 1

    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        root.masksToBounds = true
        layer = root
        wantsLayer = true
        autoresizingMask = [.width, .height]
        for sublayer in [imageLayer, playerLayer] {
            sublayer.isHidden = true
            sublayer.frame = bounds
            root.addSublayer(sublayer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutMedia()
    }

    // MARK: - Content

    func showVideo(at url: URL) {
        clear()
        videoURL = url
        playerLayer.isHidden = false
        firstFrame = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { self?.contentIsReady() }
        }
        loadPlayer()
    }

    func showImage(at url: URL) {
        clear()
        let scale = window?.backingScaleFactor ?? 2
        let longestSide = max(bounds.width, bounds.height) * scale
        // Decoding at screen resolution keeps memory low for huge photos.
        imageLayer.contents = Thumbnailer.image(at: url, maxPixelSize: Int(longestSide.rounded(.up)))
        imageLayer.isHidden = false
        contentIsReady()
    }

    /// `hearsSound` is off only for the helper that measures a wallpaper without listening to
    /// the Mac.
    func showWeb(_ project: WebProject, hearsSound: Bool = true) {
        clear()
        let webView = WebWallpaperView(frame: bounds)
        webView.hearsSound = hearsSound
        addSubview(webView)
        self.webView = webView
        webView.setAudio(muted: isMuted, volume: volume)
        webView.setPlaying(isPlaying, rate: rate)
        webView.onReady = { [weak self] in self?.contentIsReady() }
        webView.show(project)
    }

    private func contentIsReady() {
        guard !isReady else { return }
        isReady = true
        firstFrame = nil
        onReady?()
    }

    func clear() {
        isReady = false
        firstFrame = nil
        webView?.unload()
        webView?.removeFromSuperview()
        webView = nil
        loadTask?.cancel()
        loadTask = nil
        videoURL = nil
        videoHasAudio = false
        removePlayer()
        playerLayer.isHidden = true
        imageLayer.contents = nil
        imageLayer.isHidden = true
    }

    // MARK: - Playback settings

    func setPlaying(_ playing: Bool, rate: Float) {
        isPlaying = playing
        self.rate = rate
        applyPlayback()
        webView?.setPlaying(playing, rate: rate)
    }

    func setAudio(muted: Bool, volume: Float) {
        isMuted = muted
        self.volume = volume
        webView?.setAudio(muted: muted, volume: volume)
        if videoHasAudio, playerHasAudio == muted {
            // Silent and audible playback use different players, see loadPlayer().
            loadPlayer()
        } else {
            player?.isMuted = muted
            player?.volume = volume
        }
    }

    /// How the video or picture fills the view. `position` matters when filling crops it: in
    /// percent, 0 keeps the left or the top in view, 100 the right or the bottom. `mediaSize` is
    /// the size of the video or picture in pixels. A web wallpaper lays itself out.
    func setFraming(_ scaling: ScalingMode, position: Double, mediaSize: CGSize) {
        self.scaling = scaling
        self.position = position
        self.mediaSize = mediaSize
        layoutMedia()
    }

    private func layoutMedia() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var frame = bounds
        var videoGravity = AVLayerVideoGravity.resize
        var imageGravity = CALayerContentsGravity.resize
        switch scaling {
        case .fill:
            if mediaSize.width > 0, mediaSize.height > 0, bounds.width > 0, bounds.height > 0 {
                // Scaled until it covers the view; what does not fit hangs over two opposite
                // edges and is cut off, and the position says how much over which of them.
                let scale = max(bounds.width / mediaSize.width, bounds.height / mediaSize.height)
                let size = CGSize(width: mediaSize.width * scale, height: mediaSize.height * scale)
                let share = CGFloat(min(max(position, 0), 100) / 100)
                // The layer's y axis points up, so keeping the top in view is its far end.
                frame = CGRect(x: (bounds.width - size.width) * share, y: (bounds.height - size.height) * (1 - share),
                               width: size.width, height: size.height)
            } else {
                videoGravity = .resizeAspectFill
                imageGravity = .resizeAspectFill
            }
        case .fit:
            videoGravity = .resizeAspect
            imageGravity = .resizeAspect
        case .stretch:
            break
        }
        playerLayer.frame = frame
        imageLayer.frame = frame
        playerLayer.videoGravity = videoGravity
        imageLayer.contentsGravity = imageGravity
        CATransaction.commit()
    }

    // MARK: - Player

    /// Builds a looping player for the current video. While muted the player gets a video-only
    /// copy of the file: an audio track keeps the audio hardware running even when muted, which
    /// costs energy and stops the Mac from going to sleep.
    private func loadPlayer() {
        guard let url = videoURL else { return }
        let includesAudio = !isMuted
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let (item, hasAudio) = await Self.makeItem(for: url, includingAudio: includesAudio)
            guard let self, !Task.isCancelled, self.videoURL == url else { return }
            self.loadTask = nil
            self.videoHasAudio = hasAudio
            self.installPlayer(with: item, hasAudio: includesAudio && hasAudio)
            if hasAudio, self.playerHasAudio == self.isMuted {
                // The sound setting changed while the player was being built.
                self.loadPlayer()
            }
        }
    }

    private static func makeItem(for url: URL, includingAudio: Bool) async -> (item: AVPlayerItem, hasAudio: Bool) {
        let asset = AVURLAsset(url: url)
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !audioTracks.isEmpty else { return (AVPlayerItem(asset: asset), false) }
        guard
            !includingAudio,
            let video = try? await asset.loadTracks(withMediaType: .video).first,
            let (timeRange, transform) = try? await video.load(.timeRange, .preferredTransform)
        else {
            return (AVPlayerItem(asset: asset), true)
        }
        let composition = AVMutableComposition()
        guard
            let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            (try? track.insertTimeRange(timeRange, of: video, at: .zero)) != nil
        else {
            return (AVPlayerItem(asset: asset), true)
        }
        track.preferredTransform = transform
        return (AVPlayerItem(asset: composition), true)
    }

    private func installPlayer(with item: AVPlayerItem, hasAudio: Bool) {
        removePlayer()
        let player = AVQueuePlayer()
        player.isMuted = isMuted
        player.volume = volume
        // A wallpaper must never keep the display awake or show up as an AirPlay source.
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
        let looper = AVPlayerLooper(player: player, templateItem: item)
        let fileName = videoURL?.lastPathComponent ?? "video"
        looperStatus = looper.observe(\.status) { looper, _ in
            if looper.status == .failed {
                let reason = looper.error?.localizedDescription ?? "unknown error"
                Log.playback.error("Cannot play \(fileName, privacy: .public): \(reason, privacy: .public)")
            }
        }
        self.looper = looper
        self.player = player
        playerHasAudio = hasAudio
        playerLayer.player = player
        applyPlayback()
    }

    private func removePlayer() {
        looperStatus = nil
        looper?.disableLooping()
        looper = nil
        player?.pause()
        player?.removeAllItems()
        player = nil
        playerLayer.player = nil
        playerHasAudio = false
    }

    private func applyPlayback() {
        guard let player else { return }
        if isPlaying {
            if player.rate != rate {
                player.rate = rate
            }
        } else if player.rate != 0 {
            player.pause()
        }
    }
}
