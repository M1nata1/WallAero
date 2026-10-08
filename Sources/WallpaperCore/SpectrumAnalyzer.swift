import Accelerate
import Foundation

/// Turns the sound that is playing into the levels an equalizer draws: for each channel, 64 bands
/// from the low notes to the high ones, each between 0 (nothing) and 1 (as loud as it gets).
///
/// Loudness is judged against the loudest of the last moments rather than against full scale, so
/// a quiet video moves the bars as much as a loud song does. Levels rise at once and fall
/// gradually, which is what makes an equalizer readable.
public final class SpectrumAnalyzer {
    public static let bandCount = 64

    public let sampleRate: Double
    /// How many of the latest samples of each channel `levels` looks at.
    public let windowSize: Int

    /// The bands divide these frequencies evenly by pitch.
    private static let lowestFrequency = 40.0
    private static let highestFrequency = 16_000.0
    /// Music is quieter the higher it goes; this many decibels per octave are added back, so the
    /// high bands move as visibly as the low ones.
    private static let tilt = 3.0
    /// A band this many decibels under the loudest one is at zero.
    private static let range: Float = 36
    /// How fast the loudest level is forgotten, in decibels per second.
    private static let release: Float = 2
    /// Sound quieter than this never fills the bars: the hiss of a silent track stays hiss.
    private static let quietestCeiling: Float = -48
    /// How far a level may fall in a second.
    private static let fall: Float = 2.6

    private struct Band {
        /// Where the band's middle lies between the transform's bins.
        var center: Float
        /// The bins wholly inside the band; empty for the low bands, which are narrower than a bin.
        var bins: ClosedRange<Int>?
        /// Decibels added for the band's pitch.
        var gain: Float
    }

    private let bands: [Band]
    private let window: [Float]
    private let scale: Float
    private let log2Size: vDSP_Length
    private let setup: FFTSetup
    /// The loudest recent level, in decibels; the bars are measured against it.
    private var ceiling = SpectrumAnalyzer.quietestCeiling
    private var current = [Float](repeating: 0, count: 2 * SpectrumAnalyzer.bandCount)

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        // About 85 ms of sound: long enough to tell bass notes apart, short enough to follow a beat.
        let exponent = max(9, Int(log2(sampleRate * 0.085).rounded()))
        log2Size = vDSP_Length(exponent)
        windowSize = 1 << exponent
        setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: windowSize, isHalfWindow: false)
        // With this a tone at full volume reads as 1, whatever the window's size.
        scale = 1 / vDSP.sum(window)

        let binWidth = sampleRate / Double(windowSize)
        let lastBin = windowSize / 2 - 1
        let highest = min(Self.highestFrequency, sampleRate / 2 * 0.95)
        bands = (0..<Self.bandCount).map { index in
            let lower = Self.frequency(at: Double(index), upTo: highest)
            let upper = Self.frequency(at: Double(index + 1), upTo: highest)
            let middle = (lower * upper).squareRoot()
            let first = Int((lower / binWidth).rounded(.up))
            let last = min(lastBin, Int((upper / binWidth).rounded(.down)))
            return Band(center: Float(min(Double(lastBin), middle / binWidth)),
                        bins: first <= last ? first...last : nil,
                        gain: Float(Self.tilt * log2(middle / 1000)))
        }
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// The frequency a band is centred on, in hertz.
    public func frequency(ofBand index: Int) -> Double {
        Self.frequency(at: Double(index) + 0.5, upTo: min(Self.highestFrequency, sampleRate / 2 * 0.95))
    }

    private static func frequency(at position: Double, upTo highest: Double) -> Double {
        lowestFrequency * pow(highest / lowestFrequency, position / Double(bandCount))
    }

    /// The levels for the latest `windowSize` samples of each channel: the left channel's bands,
    /// then the right's, low notes first. `interval` is the time since the previous call, in seconds.
    public func levels(left: [Float], right: [Float], interval: Double) -> [Float] {
        precondition(left.count == windowSize && right.count == windowSize, "a channel must hold windowSize samples")
        let loudness = decibels(of: left) + decibels(of: right)
        let step = Float(interval)
        ceiling = max(ceiling - Self.release * step, loudness.max() ?? Self.quietestCeiling, Self.quietestCeiling)
        let floor = ceiling - Self.range
        for index in current.indices {
            let level = min(1, max(0, (loudness[index] - floor) / Self.range))
            current[index] = max(level, current[index] - Self.fall * step)
        }
        return current
    }

    /// The levels when nothing is playing: what was there falls away.
    public func silence(interval: Double) -> [Float] {
        let step = Float(interval)
        ceiling = max(ceiling - Self.release * step, Self.quietestCeiling)
        for index in current.indices {
            current[index] = max(0, current[index] - Self.fall * step)
        }
        return current
    }

    /// How loud each band of one channel is, in decibels below a tone at full volume, with the
    /// correction for pitch added.
    private func decibels(of samples: [Float]) -> [Float] {
        let half = windowSize / 2
        var windowed = [Float](repeating: 0, count: windowSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(windowSize))
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }
        return bands.map { band in
            // A low band is narrower than a bin and reads between the two nearest; a high one
            // takes the loudest of the bins it spans.
            let lower = Int(band.center)
            let upper = min(lower + 1, half - 1)
            let fraction = band.center - Float(lower)
            var magnitude = magnitudes[lower] * (1 - fraction) + magnitudes[upper] * fraction
            if let bins = band.bins {
                magnitude = max(magnitude, magnitudes[bins].max() ?? 0)
            }
            return 20 * log10(max(magnitude * scale, 1e-9)) + band.gain
        }
    }
}
