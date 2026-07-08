import Accelerate
import Foundation

enum WindowFunction: String, CaseIterable, Identifiable {
    case hann
    case hamming
    case blackman
    case rectangular

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct AudioAnalyzerSettings {
    var inputGain: Double = 1.4
    var automaticGain = true
    var smoothing: Double = 0.72
    var fftSize = 1024
    var windowFunction: WindowFunction = .hann
    var noiseFloorDB: Double = -68
    var waveformLowPassEnabled = true
    var waveformLowPassHz: Double = 400
    var minFrequency: Double = 30
    var maxFrequency: Double = 18_000
}

struct AudioAnalysisSnapshot {
    var rms: Float = 0
    var peak: Float = 0
    var envelope: Float = 0
    var spectrum: [Float] = Array(repeating: 0, count: 128)
    var bands: FrequencyBands = .zero
    var stereo: (left: Float, right: Float) = (0, 0)
    var waveform: [Float] = Array(repeating: 0, count: 256)
    var lowPassWaveform: [Float] = Array(repeating: 0, count: 256)
    var oscilloscopeWaveform: [Float] = Array(repeating: 0, count: 256)
}

struct FrequencyBands {
    var subBass: Float
    var bass: Float
    var lowMids: Float
    var mids: Float
    var upperMids: Float
    var treble: Float

    static let zero = FrequencyBands(subBass: 0, bass: 0, lowMids: 0, mids: 0, upperMids: 0, treble: 0)
}

@MainActor
final class AudioAnalyzer: ObservableObject {
    @Published var settings = AudioAnalyzerSettings()
    @Published private(set) var snapshot = AudioAnalysisSnapshot()

    weak var source: AudioRingBuffer?

    private var previousSpectrum = Array(repeating: Float(0), count: 128)
    private var envelope: Float = 0
    private var agcGain: Float = 1

    func analyze() -> AudioAnalysisSnapshot {
        let fftSize = max(512, min(4096, settings.fftSize))
        guard let samples = source?.latestMono(frameCount: fftSize), samples.count == fftSize else {
            return snapshot
        }

        var gain = Float(settings.inputGain)
        if settings.automaticGain {
            let currentRMS = max(computeRMS(samples), 0.000_01)
            let target: Float = 0.18
            agcGain = agcGain * 0.985 + min(8, target / currentRMS) * 0.015
            gain *= agcGain
        }

        var working = samples.map { max(-1, min(1, $0 * gain)) }
        let peak = working.map { abs($0) }.max() ?? 0
        let rms = computeRMS(working)
        envelope = max(rms, envelope * 0.90)

        applyWindow(&working, kind: settings.windowFunction)
        let spectrum = computeSpectrum(samples: working, outputBins: 128)
        let smooth = Float(settings.smoothing)
        let smoothed = zip(previousSpectrum, spectrum).map { old, new in old * smooth + new * (1 - smooth) }
        previousSpectrum = smoothed

        let bands = computeBands(spectrum: smoothed, fftSize: fftSize)
        let waveform = downsampleWaveform(samples)
        let lowPassWaveform = downsampleWaveform(lowPass(samples,
                                                        cutoffHz: settings.waveformLowPassHz,
                                                        sampleRate: source?.sampleRate ?? 48_000))
        let oscilloscopeWaveform = settings.waveformLowPassEnabled ? lowPassWaveform : waveform
        let stereo = source?.latestStereoLevels(frameCount: fftSize) ?? (0, 0)

        let next = AudioAnalysisSnapshot(rms: rms,
                                         peak: peak,
                                         envelope: envelope,
                                         spectrum: smoothed,
                                         bands: bands,
                                         stereo: stereo,
                                         waveform: waveform,
                                         lowPassWaveform: lowPassWaveform,
                                         oscilloscopeWaveform: oscilloscopeWaveform)
        snapshot = next
        return next
    }

    private func computeRMS(_ samples: [Float]) -> Float {
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
        return sqrt(meanSquare)
    }

    private func applyWindow(_ samples: inout [Float], kind: WindowFunction) {
        guard kind != .rectangular else { return }
        var window = Array(repeating: Float(0), count: samples.count)
        switch kind {
        case .hann:
            vDSP_hann_window(&window, vDSP_Length(samples.count), Int32(vDSP_HANN_NORM))
        case .hamming:
            vDSP_hamm_window(&window, vDSP_Length(samples.count), 0)
        case .blackman:
            vDSP_blkman_window(&window, vDSP_Length(samples.count), 0)
        case .rectangular:
            break
        }
        vDSP.multiply(samples, window, result: &samples)
    }

    private func computeSpectrum(samples: [Float], outputBins: Int) -> [Float] {
        let n = samples.count
        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return Array(repeating: 0, count: outputBins)
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var real = Array(repeating: Float(0), count: n / 2)
        var imag = Array(repeating: Float(0), count: n / 2)
        var magnitudes = Array(repeating: Float(0), count: n / 2)
        real.withUnsafeMutableBufferPointer { realBuffer in
            imag.withUnsafeMutableBufferPointer { imagBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                samples.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complexPointer in
                        vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }

        let floorDB = Float(settings.noiseFloorDB)
        var bins = Array(repeating: Float(0), count: outputBins)
        for i in 0..<outputBins {
            let start = max(1, Int(pow(Double(i) / Double(outputBins), 1.8) * Double(magnitudes.count - 1)))
            let end = max(start + 1, Int(pow(Double(i + 1) / Double(outputBins), 1.8) * Double(magnitudes.count - 1)))
            let slice = magnitudes[start..<min(end, magnitudes.count)]
            let average = slice.reduce(Float(0), +) / Float(max(1, slice.count))
            let db = 10 * log10(max(average, 0.000_000_01))
            bins[i] = max(0, min(1, (db - floorDB) / abs(floorDB)))
        }
        return bins
    }

    private func computeBands(spectrum: [Float], fftSize: Int) -> FrequencyBands {
        func average(_ range: Range<Int>) -> Float {
            let lower = max(0, range.lowerBound)
            let upper = min(spectrum.count, range.upperBound)
            guard upper > lower else { return 0 }
            return spectrum[lower..<upper].reduce(0, +) / Float(upper - lower)
        }

        return FrequencyBands(subBass: average(0..<7),
                              bass: average(7..<18),
                              lowMids: average(18..<34),
                              mids: average(34..<60),
                              upperMids: average(60..<92),
                              treble: average(92..<128))
    }

    private func downsampleWaveform(_ samples: [Float]) -> [Float] {
        let outputCount = 256
        let stride = max(1, samples.count / outputCount)
        return (0..<outputCount).map { index in
            let start = index * stride
            let end = min(samples.count, start + stride)
            guard start < end else { return 0 }
            return samples[start..<end].reduce(0, +) / Float(end - start)
        }
    }

    private func lowPass(_ samples: [Float], cutoffHz: Double, sampleRate: Double) -> [Float] {
        guard !samples.isEmpty, cutoffHz > 0, sampleRate > 0 else { return samples }

        let clampedCutoff = min(cutoffHz, sampleRate * 0.45)
        let rc = 1.0 / (2.0 * Double.pi * clampedCutoff)
        let dt = 1.0 / sampleRate
        let alpha = Float(dt / (rc + dt))
        var filtered = Array(repeating: Float(0), count: samples.count)
        var y = samples[0]

        for index in samples.indices {
            y += alpha * (samples[index] - y)
            filtered[index] = y
        }

        return filtered
    }
}
