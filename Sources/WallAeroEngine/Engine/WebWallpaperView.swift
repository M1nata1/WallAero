import AppKit
import CoreServices
import WallpaperCore
import WebKit

/// Shows a web wallpaper — a scene or any page of the library — in a web view.
///
/// Pausing hides the web view behind a still of itself: a hidden page stops its videos, its
/// animations and its timers, which is what saves the energy, whatever the page is made of.
@MainActor
final class WebWallpaperView: NSView, WKNavigationDelegate {
    /// Called, on the main thread, when the wallpaper's files change on disk.
    var onContentChange: (() -> Void)?

    /// Set before `show` when the page is rendered for the still picture macOS shows on the lock
    /// screen: a scene then leaves out the layers that are not meant to appear there.
    var rendersStill = false

    /// Set before `show` to let the page have the spectrum of the sound the Mac is playing, if it
    /// asks for it. The wallpaper on the desktop and the editor's preview do; the pictures
    /// rendered off screen do not, and so never set the listening off.
    var hearsSound = false

    /// Called when the page has something to show: it has loaded and its videos have their
    /// first frame. Also called when the page fails to load, and a few seconds after `show` at
    /// the latest, so that whoever keeps the wallpaper out of sight until then never waits for good.
    var onReady: (() -> Void)?

    /// Makes the web engine refuse to start any video or sound by itself, the way it refuses
    /// videos in Low Power Mode. Only the helper that checks that the app starts them sets this.
    var mediaNeedsUserAction = false

    // The scene editor shows its preview with this view too. These are set before `show`.
    /// A script added to the page after its own; its `wallaeroEditor` messages go to `onEditorMessage`.
    var editorScript: String?
    var onEditorMessage: (([String: Any]) -> Void)?
    /// The editor owns the scene and pushes it to the page itself. When this is set, a change of
    /// the scene file is reported here instead of being shown.
    var onSceneFileChange: (() -> Void)?

    private var webView: WKWebView?
    private let stillView = NSImageView()
    private var project: WebProject?
    private var watcher: FolderWatcher?

    private var hasLoaded = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReady = false
    /// Tells a late answer that it belongs to a page that has since been loaded anew.
    private var loadGeneration = 0
    private static let longestWaitForPage: TimeInterval = 3
    private var isFrozen = false
    /// Tells a late snapshot or timer that the state it was made for is gone.
    private var freezeGeneration = 0

    // Requested playback state, applied once the page is there.
    private var isPlaying = false
    private var rate: Float = 1
    private var isMuted = true
    private var volume: Float = 1

    /// Whether the page has a listener for the sound, and whether it is being given any.
    private var pageWantsSound = false
    private var isHearingSound = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        autoresizingMask = [.width, .height]
        stillView.imageScaling = .scaleAxesIndependently
        stillView.autoresizingMask = [.width, .height]
        stillView.frame = bounds
        stillView.isHidden = true
        addSubview(stillView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Content

    func show(_ project: WebProject, watchingForChanges: Bool = true) {
        unload()
        self.project = project
        if project.isScene {
            // Scenes made by an older version of the app get the current page and runtime.
            _ = try? SceneProject.refreshGeneratedFiles(in: project.folder)
        }

        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = mediaNeedsUserAction ? .all : []
        installUserScripts(in: configuration.userContentController, for: project)
        configuration.userContentController.add(MessageRelay { [weak self] in self?.hostMessage($0) }, name: "wallaeroHost")
        if editorScript != nil {
            configuration.userContentController.add(MessageRelay { [weak self] in self?.onEditorMessage?($0) }, name: "wallaeroEditor")
        }
        let webView = WKWebView(frame: bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        // Black shows through until the page has drawn, instead of a white flash.
        webView.setValue(false, forKey: "drawsBackground")
        addSubview(webView, positioned: .below, relativeTo: stillView)
        self.webView = webView
        beginLoading()
        webView.loadFileURL(project.entryURL, allowingReadAccessTo: project.folder)

        if watchingForChanges {
            watcher = FolderWatcher(folder: project.folder) { [weak self] paths in
                self?.filesDidChange(paths)
            }
        }
    }

    func unload() {
        watcher = nil
        freezeGeneration += 1
        loadGeneration += 1
        isReady = false
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        project = nil
        hasLoaded = false
        isFrozen = false
        stillView.image = nil
        stillView.isHidden = true
        pageWantsSound = false
        updateSound()
        resumeLoadWaiters()
    }

    /// Returns once the page has finished loading (or failed to).
    func waitUntilLoaded() async {
        guard webView != nil, !hasLoaded else { return }
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    /// Runs a script in the page, once it is there.
    func evaluate(_ script: String) {
        guard hasLoaded else { return }
        webView?.evaluateJavaScript(script)
    }

    /// What a script evaluates to in the page; nil if it fails or the page is not there.
    func value(of script: String) async -> Any? {
        guard hasLoaded, let webView else { return nil }
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in continuation.resume(returning: value) }
        }
    }

    /// Whether the page is hidden behind a still of itself, as it is while paused.
    var isShowingStill: Bool { !stillView.isHidden }

    /// A picture of the page as it looks now.
    func snapshot() async -> CGImage? {
        guard let webView else { return nil }
        let image: NSImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, _ in continuation.resume(returning: image) }
        }
        return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: - Playback settings

    func setPlaying(_ playing: Bool, rate: Float) {
        isPlaying = playing
        if rate != self.rate {
            self.rate = rate
            applyHostSettings()
        }
        applyPlaying()
        updateSound()
    }

    func setAudio(muted: Bool, volume: Float) {
        guard muted != isMuted || volume != self.volume else { return }
        isMuted = muted
        self.volume = volume
        applyHostSettings()
    }

    private func applyHostSettings() {
        guard hasLoaded else { return }
        webView?.evaluateJavaScript("window.__wallaeroHost && window.__wallaeroHost.apply(\(hostSettingsJSON))")
    }

    private var hostSettingsJSON: String {
        "{rate: \(rate), muted: \(isMuted), volume: \(max(0, min(1, volume)))}"
    }

    private func applyPlaying() {
        guard hasLoaded, let webView else { return }
        if isPlaying, isFrozen {
            isFrozen = false
            freezeGeneration += 1
            let generation = freezeGeneration
            webView.isHidden = false
            // The page takes a moment to draw again; the still covers it until then.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.freezeGeneration == generation else { return }
                self.stillView.isHidden = true
                self.stillView.image = nil
            }
        } else if !isPlaying, !isFrozen {
            isFrozen = true
            freezeGeneration += 1
            let generation = freezeGeneration
            webView.takeSnapshot(with: nil) { [weak self] image, _ in
                guard let self, self.freezeGeneration == generation else { return }
                self.stillView.image = image
                self.stillView.isHidden = false
                self.webView?.isHidden = true
            }
        }
    }

    // MARK: - Sound

    private func hostMessage(_ message: [String: Any]) {
        if let wanted = message["sound"] as? Bool {
            pageWantsSound = wanted
            updateSound()
        }
        if message["ready"] != nil {
            pageIsReady()
        }
    }

    /// The page is given the sound only while it asks for it and is playing: listening to the
    /// Mac for a paused wallpaper would be for nothing.
    private func updateSound() {
        let wanted = hearsSound && pageWantsSound && hasLoaded && isPlaying
        guard wanted != isHearingSound else { return }
        isHearingSound = wanted
        if wanted {
            SoundSpectrum.shared.addListener(self) { [weak self] script in
                self?.webView?.evaluateJavaScript(script)
            }
        } else {
            SoundSpectrum.shared.removeListener(self)
        }
    }

    // MARK: - Loading

    private func beginLoading() {
        isReady = false
        loadGeneration += 1
        let generation = loadGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.longestWaitForPage) { [weak self] in
            guard let self, self.loadGeneration == generation else { return }
            self.pageIsReady()
        }
    }

    private func pageIsReady() {
        guard !isReady, webView != nil else { return }
        isReady = true
        if !isFrozen {
            // The picture that covered a page loading anew has done its job.
            stillView.isHidden = true
            stillView.image = nil
        }
        onReady?()
    }

    /// A page is blank while it loads again. A picture of how it looked covers that; a paused
    /// wallpaper already has its still in front.
    private func coverWhileLoading(_ webView: WKWebView) {
        guard stillView.isHidden else { return }
        let generation = loadGeneration
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let self, let image, self.loadGeneration == generation, !self.isReady, !self.isFrozen else { return }
            self.stillView.image = image
            self.stillView.isHidden = false
        }
    }

    // MARK: - Page set-up

    private func installUserScripts(in controller: WKUserContentController, for project: WebProject) {
        controller.removeAllUserScripts()
        var source = Self.bridgeScript.replacingOccurrences(of: "__HOST_SETTINGS__", with: hostSettingsJSON)
        if project.isScene, let scene = Self.sceneJSON(in: project.folder) {
            // File pages cannot fetch files, so the scene is handed to the runtime directly.
            source += "\nwindow.wallaeroScene = \(scene);"
        }
        if rendersStill {
            source += "\nwindow.wallaeroStill = true;"
        }
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let editorScript {
            controller.addUserScript(WKUserScript(source: editorScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
    }

    /// The scene file's text, if it is valid JSON; it goes to the page as is, unknown keys and all.
    private static func sceneJSON(in folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(SceneProject.sceneFileName)),
              (try? JSONSerialization.jsonObject(with: data)) != nil
        else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs before the page's own scripts. Keeps every video and sound of the page at the app's
    /// speed and volume, and stands in for the parts of Wallpaper Engine's API pages rely on.
    private static let bridgeScript = #"""
    (function () {
      var host = __HOST_SETTINGS__;
      function applyTo(media) {
        if (!(media instanceof HTMLMediaElement)) return;
        if (media.playbackRate !== host.rate) {
          media.defaultPlaybackRate = host.rate;
          media.playbackRate = host.rate;
        }
        if (media.muted !== host.muted) media.muted = host.muted;
        if (media.volume !== host.volume) media.volume = host.volume;
        // A muted video whose audio track is still enabled keeps the audio hardware running,
        // and with it the Mac awake. Switching the track off lets both rest.
        if (media.audioTracks) {
          var audible = !host.muted && host.volume > 0;
          for (var i = 0; i < media.audioTracks.length; i++) {
            if (media.audioTracks[i].enabled !== audible) media.audioTracks[i].enabled = audible;
          }
        }
        start(media);
      }
      // In Low Power Mode WebKit does not start a video by itself, and over one marked
      // `autoplay` it draws a start button of its own, which a page cannot hide. So the mark
      // is taken off and the video is started from here instead. A script the app runs counts
      // as the user's own action, which may start a video in any mode; `apply` is how the app
      // does that once the page has loaded.
      var autoplaying = new WeakSet();
      function start(media) {
        if (media.autoplay) {
          media.autoplay = false;
          autoplaying.add(media);
        }
        if (autoplaying.has(media) && media.paused && !media.ended && !media.played.length) {
          var started = media.play();
          if (started && started.catch) started.catch(function () {});
        }
      }
      function applyAll() {
        var all = document.querySelectorAll('video, audio');
        for (var i = 0; i < all.length; i++) applyTo(all[i]);
      }
      // Media events do not bubble, but they can be caught on the way down.
      ['loadstart', 'loadedmetadata', 'play'].forEach(function (name) {
        document.addEventListener(name, function (event) { applyTo(event.target); }, true);
      });
      window.__wallaeroHost = {
        apply: function (settings) {
          for (var key in settings) host[key] = settings[key];
          applyAll();
        },
        // For a page that knows the app: a video to be played without ever being marked `autoplay`.
        autoplay: function (media) {
          autoplaying.add(media);
          applyTo(media);
        }
      };
      // The app keeps a wallpaper out of sight until there is something to see, and a page
      // that loads anew covered until then. It is told when the page has loaded and every
      // video on it has its first frame.
      window.addEventListener('load', function () {
        var waiting = 1;
        function settle() {
          if (--waiting > 0) return;
          var told = false;
          function tell() {
            if (told) return;
            told = true;
            try {
              window.webkit.messageHandlers.wallaeroHost.postMessage({ ready: true });
            } catch (error) {}
          }
          // Two frames on, the picture has been drawn. A hidden page draws none, hence the timer.
          requestAnimationFrame(function () { requestAnimationFrame(tell); });
          setTimeout(tell, 150);
        }
        Array.prototype.forEach.call(document.querySelectorAll('video'), function (video) {
          if (video.readyState >= 2 || video.error || !(video.currentSrc || video.src)) return;
          waiting++;
          var counted = false;
          function once() {
            if (counted) return;
            counted = true;
            settle();
          }
          video.addEventListener('loadeddata', once);
          video.addEventListener('error', once);
        });
        settle();
      });
      // Wallpaper Engine's way for a page to follow the sound: the listener gets 128 numbers,
      // 64 bands of the left channel and 64 of the right, low notes first, each from 0 to 1.
      // Here they describe whatever the Mac is playing. The app is told when a page listens,
      // so the Mac's sound is not picked up for pages that have no use for it.
      var soundListeners = [];
      function tellAboutSound() {
        try {
          window.webkit.messageHandlers.wallaeroHost.postMessage({ sound: soundListeners.length > 0 });
        } catch (error) {}
      }
      window.wallpaperRegisterAudioListener = function (listener) {
        if (typeof listener !== 'function') return;
        // A scene's layer is rebuilt when it is edited; `owner` is the element whose script is
        // registering, so that the listener goes when the element does.
        soundListeners.push({ call: listener, owner: window.__wallaeroHost.owner || null });
        if (soundListeners.length === 1) tellAboutSound();
      };
      window.__wallaeroHost.sound = function (levels) {
        var kept = soundListeners.filter(function (entry) { return !entry.owner || entry.owner.isConnected; });
        if (kept.length !== soundListeners.length) {
          soundListeners = kept;
          if (!kept.length) tellAboutSound();
        }
        kept.forEach(function (entry) {
          try {
            entry.call(levels);
          } catch (error) {
            console.error(error);
          }
        });
      };
      // The rest of what Wallpaper Engine pages call on start-up: there is nothing to tell them
      // here, but the page loads instead of failing.
      ['wallpaperRegisterMediaStatusListener', 'wallpaperRegisterMediaPropertiesListener',
       'wallpaperRegisterMediaThumbnailListener', 'wallpaperRegisterMediaPlaybackListener',
       'wallpaperRegisterMediaTimelineListener'].forEach(function (name) {
        if (!window[name]) window[name] = function () {};
      });
    })();
    """#

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        if let properties = project?.userPropertiesJSON {
            // The wallpaper's own settings, at the values its author chose.
            webView.evaluateJavaScript("""
            (function (properties) {
              var listener = window.wallpaperPropertyListener;
              if (listener && typeof listener.applyUserProperties === 'function') listener.applyUserProperties(properties);
            })(\(properties));
            """)
        }
        pageDidSettle()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageFailed(webView, error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageFailed(webView, error)
    }

    private func pageFailed(_ webView: WKWebView, _ error: Error) {
        guard webView === self.webView else { return }
        Log.playback.error("Cannot show the web wallpaper \(self.project?.folder.lastPathComponent ?? "?", privacy: .public): \(error.localizedDescription, privacy: .public)")
        pageDidSettle()
        pageIsReady()
    }

    private func pageDidSettle() {
        hasLoaded = true
        applyHostSettings()
        updateSound()
        resumeLoadWaiters()
        if isPlaying {
            applyPlaying()
        } else {
            // Paused from the start: let the page draw its first frame, then freeze on it.
            let generation = freezeGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.freezeGeneration == generation else { return }
                self.applyPlaying()
            }
        }
    }

    private func resumeLoadWaiters() {
        let waiters = loadWaiters
        loadWaiters = []
        waiters.forEach { $0.resume() }
    }

    // MARK: - Live reload

    private func filesDidChange(_ paths: [String]) {
        guard let project, let webView else { return }
        // Saving a file safely writes a hidden temporary one first and renames it; those are not
        // changes to the wallpaper, and neither is Finder's own bookkeeping.
        let names = Set(paths.map { ($0 as NSString).lastPathComponent }).filter { !$0.hasPrefix(".") && !$0.contains(".sb-") }
        guard !names.isEmpty else { return }
        if project.isScene, names == [SceneProject.sceneFileName] {
            if let onSceneFileChange {
                onSceneFileChange()
                return
            }
            // Only the scene changed: redraw it in place, so the video does not start over.
            installUserScripts(in: webView.configuration.userContentController, for: project)
            if let scene = Self.sceneJSON(in: project.folder) {
                webView.evaluateJavaScript("window.wallaero && window.wallaero.setScene(\(scene))")
            }
        } else if let reread = WebProject(folder: project.folder) {
            self.project = reread
            installUserScripts(in: webView.configuration.userContentController, for: reread)
            hasLoaded = false
            pageWantsSound = false
            updateSound()
            beginLoading()
            coverWhileLoading(webView)
            webView.isHidden = false
            isFrozen = false
            freezeGeneration += 1
            webView.loadFileURL(reread.entryURL, allowingReadAccessTo: reread.folder)
        }
        onContentChange?()
    }
}

/// Hands a page's messages on without the page keeping the view alive.
private final class MessageRelay: NSObject, WKScriptMessageHandler {
    private let handler: ([String: Any]) -> Void

    init(handler: @escaping ([String: Any]) -> Void) {
        self.handler = handler
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        handler(body)
    }
}

/// Reports changes to the files of a folder, at any depth, a moment after they happen.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    init?(folder: URL, handler: @escaping ([String]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info, let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.handler(Array(paths.prefix(count)))
        }
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                               FSEventStreamCreateFlags(flags)) else {
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
