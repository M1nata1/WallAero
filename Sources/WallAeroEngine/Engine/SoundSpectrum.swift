import Accelerate
import CoreAudio
import Foundation
import WallpaperCore

/// Gives web wallpapers the spectrum of whatever the Mac is playing, so that an equalizer in a
/// scene moves to the music of any app.
///
/// The Mac's sound is listened to only while a wallpaper that asked for it is playing on screen,
/// and nothing is kept: each moment of sound becomes 128 numbers and is dropped. Pages get those
/// numbers about thirty times a second; in silence, a few times a second, so that they can tell
/// silence from not being told anything.
@MainActor
final class SoundSpectrum {
    static let shared = SoundSpectrum()

    /// The user's choice in the settings.
    var isEnabled = true {
        didSet {
            if isEnabled != oldValue { update() }
        }
    }

    private struct Listener {
        weak var owner: AnyObject?
        let handler: (String) -> Void
    }

    /// Where the sound comes from. Nil means the Mac itself; the helper that checks the
    /// listening without the Mac's sound puts a made-up source here before anything listens.
    var makeSource: (() -> SoundSource)? {
        get { capture.makeSource }
        set { capture.makeSource = newValue }
    }

    private var listeners: [ObjectIdentifier: Listener] = [:]
    private let capture = Capture()
    private var isCapturing = false
    private var pendingStop: Task<Void, Never>?

    private init() {
        capture.onScript = { [weak self] script in
            Task { @MainActor in self?.deliver(script) }
        }
    }

    /// Starts handing `handler` the script that passes the latest levels to a page. The owner is
    /// not kept alive; when it goes away, so does its handler.
    func addListener(_ owner: AnyObject, handler: @escaping (String) -> Void) {
        listeners[ObjectIdentifier(owner)] = Listener(owner: owner, handler: handler)
        update()
    }

    func removeListener(_ owner: AnyObject) {
        guard listeners.removeValue(forKey: ObjectIdentifier(owner)) != nil else { return }
        update()
    }

    private func deliver(_ script: String) {
        guard isEnabled else { return }
        var someoneLeft = false
        for (key, listener) in listeners {
            if listener.owner == nil {
                listeners[key] = nil
                someoneLeft = true
            } else {
                listener.handler(script)
            }
        }
        if someoneLeft { update() }
    }

    private func update() {
        let wanted = isEnabled && !listeners.isEmpty
        if wanted {
            pendingStop?.cancel()
            pendingStop = nil
            if !isCapturing {
                isCapturing = true
                capture.start()
            }
        } else if isCapturing, pendingStop == nil {
            // A wallpaper pauses and plays again every time a window passes over the desktop;
            // the listening is not set up anew for each of those moments.
            let delay: UInt64 = isEnabled ? 5_000_000_000 : 0
            pendingStop = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self else { return }
                self.pendingStop = nil
                self.isCapturing = false
                self.capture.stop()
            }
        }
    }

    /// The script that hands levels to a page; `__wallaeroHost` is the bridge of `WebWallpaperView`.
    nonisolated static func script(for levels: [Float]) -> String {
        var text = "window.__wallaeroHost&&window.__wallaeroHost.sound(["
        text.reserveCapacity(text.count + levels.count * 6 + 2)
        for (index, level) in levels.enumerated() {
            if index > 0 { text.append(",") }
            // Thousandths, written out by hand: this runs for every band, thirty times a second.
            let thousandths = Int((min(level, 1) * 1000).rounded())
            if thousandths <= 0 {
                text.append("0")
            } else if thousandths >= 1000 {
                text.append("1")
            } else {
                text.append("0.")
                text.append(contentsOf: String(1000 + thousandths).dropFirst())
            }
        }
        text.append("])")
        return text
    }
}

/// Something that hands over sound as it plays: the tap on the Mac's sound, or a made-up signal
/// for checking what is done with it.
protocol SoundSource: AnyObject {
    var sampleRate: Double { get }
    /// Starts handing the sound to `handler`, on `queue`, as 32-bit floating-point samples.
    func start(on queue: DispatchQueue, handler: @escaping (UnsafePointer<AudioBufferList>) -> Void) throws
    func stop()
}

/// The listening itself. Everything here happens on one queue of its own: the sound arrives on
/// it, and starting waits on it for as long as macOS is asking the user for permission.
///
/// It is background work and is scheduled as such, which on Apple silicon keeps it on the
/// efficiency cores. While nothing sounds it rests: the levels are worked out four times a second
/// instead of thirty, and the first sound that arrives brings the pace back.
private final class Capture {
    /// Called on the capture's queue with the script for the latest levels.
    var onScript: ((String) -> Void)?
    /// Makes the source of the sound; nil means the tap on the Mac's own.
    var makeSource: (() -> SoundSource)?

    private static let framesPerSecond = 30.0
    /// How often pages hear from the app while nothing is playing, in seconds.
    private static let silenceInterval = 0.25
    private static let silentScript = SoundSpectrum.script(for: [Float](repeating: 0, count: 2 * SpectrumAnalyzer.bandCount))
    /// A sample this far from zero ends the rest. It is well under what moves a band, so the
    /// rest never costs the start of a sound.
    private static let wakingLevel: Float = 3e-5
    /// After this many ticks without a level above zero, a second's worth, the rest begins.
    private static let ticksBeforeRest = 30

    private let queue = DispatchQueue(label: "com.fadevec.WallAeroEngine.sound", qos: .utility)
    private var tap: SoundSource?
    private var timer: DispatchSourceTimer?
    private var analyzer: SpectrumAnalyzer?
    private var watchesOutputDevice = false

    // The latest sound of each channel, written in a circle.
    private var left: [Float] = []
    private var right: [Float] = []
    private var writeIndex = 0
    private var lastSound = DispatchTime(uptimeNanoseconds: 0)
    private var lastSilentScript = DispatchTime(uptimeNanoseconds: 0)
    private var isFlat = false
    private var flatTicks = 0
    private var isResting = false

    func start() {
        queue.async { self.begin() }
    }

    func stop() {
        queue.async { self.end() }
    }

    private func begin() {
        guard tap == nil else { return }
        let tap: SoundSource
        if let makeSource {
            tap = makeSource()
        } else if #available(macOS 14.2, *) {
            tap = SystemAudioTap()
        } else {
            return // older systems cannot be listened to
        }
        do {
            try tap.start(on: queue) { [weak self] buffers in
                self?.append(buffers)
            }
        } catch {
            Log.playback.error("Cannot listen to the Mac's sound: \(String(describing: error), privacy: .public)")
            return
        }
        self.tap = tap
        let analyzer = SpectrumAnalyzer(sampleRate: tap.sampleRate)
        self.analyzer = analyzer
        left = [Float](repeating: 0, count: analyzer.windowSize)
        right = left
        writeIndex = 0
        isFlat = false
        flatTicks = 0
        isResting = false
        Log.playback.info("Listening to the Mac's sound at \(Int(tap.sampleRate), privacy: .public) Hz")

        // Strict: macOS spaces out the timers of work it takes for background work, down to a
        // dozen a second, and an equalizer fed that unevenly stutters.
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: 1 / Self.framesPerSecond, leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        watchOutputDevice()
    }

    private func end() {
        timer?.cancel()
        timer = nil
        if let tap {
            tap.stop()
            Log.playback.info("Stopped listening to the Mac's sound")
        }
        tap = nil
        analyzer = nil
    }

    /// Headphones plugged in, AirPods connected: the sound goes elsewhere, possibly at another
    /// sample rate, so the listening starts afresh.
    private func watchOutputDevice() {
        guard !watchesOutputDevice else { return }
        watchesOutputDevice = true
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue) { [weak self] _, _ in
            guard let self, self.tap != nil else { return }
            self.end()
            self.begin()
        }
    }

    private func setResting(_ resting: Bool) {
        guard resting != isResting, let timer else { return }
        isResting = resting
        flatTicks = 0
        if resting {
            timer.schedule(deadline: .now() + Self.silenceInterval, repeating: Self.silenceInterval, leeway: .milliseconds(50))
        } else {
            timer.schedule(deadline: .now(), repeating: 1 / Self.framesPerSecond, leeway: .milliseconds(4))
        }
    }

    private func append(_ buffers: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers))
        guard let first = list.first, let firstData = first.mData, !left.isEmpty else { return }
        let size = left.count
        let firstSamples = firstData.assumingMemoryBound(to: Float.self)
        let channels = Int(first.mNumberChannels)
        if channels >= 2 {
            // Both channels in one buffer, sample by sample.
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            for frame in 0..<frames {
                left[writeIndex] = firstSamples[frame * channels]
                right[writeIndex] = firstSamples[frame * channels + 1]
                writeIndex = (writeIndex + 1) % size
            }
        } else {
            // A buffer for each channel; a single one is mono and goes to both sides.
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let second = list.count > 1 ? list[1].mData?.assumingMemoryBound(to: Float.self) : nil
            for frame in 0..<frames {
                left[writeIndex] = firstSamples[frame]
                right[writeIndex] = (second ?? firstSamples)[frame]
                writeIndex = (writeIndex + 1) % size
            }
        }
        lastSound = .now()
        if isResting {
            var loudest: Float = 0
            vDSP_maxmgv(firstSamples, 1, &loudest, vDSP_Length(Int(first.mDataByteSize) / MemoryLayout<Float>.size))
            if loudest >= Self.wakingLevel {
                setResting(false)
            }
        }
    }

    private func tick() {
        guard let analyzer else { return }
        let now = DispatchTime.now()
        let interval = isResting ? Self.silenceInterval : 1 / Self.framesPerSecond
        // With nothing playing the sound may stop arriving altogether; what is left in the
        // buffers then is old.
        let isArriving = now.uptimeNanoseconds - lastSound.uptimeNanoseconds < 150_000_000
        var levels: [Float]
        if isArriving, !isSilent(left) || !isSilent(right) {
            levels = analyzer.levels(left: inOrder(left), right: inOrder(right), interval: interval)
        } else {
            levels = analyzer.silence(interval: interval)
        }
        if levels.contains(where: { $0 > 0 }) {
            isFlat = false
            flatTicks = 0
            onScript?(SoundSpectrum.script(for: levels))
            return
        }
        // Zeros go out at once when the sound stops, and after that only as often as a page
        // needs them to know that what it hears is silence.
        if !isFlat || isResting || Double(now.uptimeNanoseconds - lastSilentScript.uptimeNanoseconds) >= Self.silenceInterval * 1e9 {
            isFlat = true
            lastSilentScript = now
            onScript?(Self.silentScript)
        }
        flatTicks += 1
        if flatTicks >= Self.ticksBeforeRest {
            setResting(true)
        }
    }

    private func isSilent(_ samples: [Float]) -> Bool {
        var loudest: Float = 0
        vDSP_maxmgv(samples, 1, &loudest, vDSP_Length(samples.count))
        return loudest < 1e-7
    }

    /// The circle unrolled, oldest sample first.
    private func inOrder(_ samples: [Float]) -> [Float] {
        Array(samples[writeIndex...] + samples[..<writeIndex])
    }
}

/// A tap on everything the Mac plays, mixed down to stereo (Core Audio process taps).
///
/// macOS asks the user once whether the app may listen. Until they answer, `start` waits; if
/// they refuse, it still succeeds and the tap delivers silence.
@available(macOS 14.2, *)
final class SystemAudioTap: SoundSource {
    struct Failure: Error, CustomStringConvertible {
        let step: String
        let status: OSStatus
        var description: String { "\(step) failed (\(status))" }
    }

    private(set) var sampleRate = 48_000.0
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    deinit {
        stop()
    }

    /// Starts handing the sound to `handler`, on `queue`, as 32-bit floating-point samples.
    /// Never call it on the main thread: it waits while the permission alert is on screen.
    func start(on queue: DispatchQueue, handler: @escaping (UnsafePointer<AudioBufferList>) -> Void) throws {
        do {
            try create(on: queue, handler: handler)
        } catch {
            stop()
            throw error
        }
    }

    private func create(on queue: DispatchQueue, handler: @escaping (UnsafePointer<AudioBufferList>) -> Void) throws {
        func check(_ status: OSStatus, _ step: String) throws {
            if status != noErr { throw Failure(step: step, status: status) }
        }
        // Every app's sound, this one's music included, as it is before the volume is applied.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "WallAero Engine"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the tap")

        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "Reading the tap's format")
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mSampleRate > 0
        else {
            throw Failure(step: "Reading the tap's format (not 32-bit float)", status: kAudioHardwareUnsupportedOperationError)
        }
        sampleRate = format.mSampleRate

        // A tap is read through a device made for it. The device holds nothing but the tap, so no
        // speaker or microphone is switched on for the listening.
        let device: [String: Any] = [
            kAudioAggregateDeviceNameKey: "WallAero Engine",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(device as CFDictionary, &deviceID), "Creating the device")
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { _, input, _, _, _ in
            handler(input)
        }, "Attaching to the device")
        try check(AudioDeviceStart(deviceID, procID), "Starting the device")
    }

    func stop() {
        if deviceID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(deviceID, procID)
                AudioDeviceDestroyIOProcID(deviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(deviceID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}
