import Foundation
import SwiftUI

enum VisualizerKind: String, CaseIterable, Identifiable {
    case spectrumBars
    case oscilloscope
    case bassGlow
    case vuMeter
    case stereoMeter
    case waterfall
    case radialSpectrum
    case debugBins

    var id: String { rawValue }

    var label: String {
        switch self {
        case .spectrumBars: "Spectrum bars"
        case .oscilloscope: "Oscilloscope"
        case .bassGlow: "Bass glow"
        case .vuMeter: "VU meter"
        case .stereoMeter: "Stereo meter"
        case .waterfall: "Waterfall"
        case .radialSpectrum: "Radial spectrum"
        case .debugBins: "Debug bins"
        }
    }
}

struct RGBPixel {
    var r: Float
    var g: Float
    var b: Float

    static let black = RGBPixel(r: 0, g: 0, b: 0)

    static func *(pixel: RGBPixel, scalar: Float) -> RGBPixel {
        RGBPixel(r: pixel.r * scalar, g: pixel.g * scalar, b: pixel.b * scalar)
    }

    static func +(lhs: RGBPixel, rhs: RGBPixel) -> RGBPixel {
        RGBPixel(r: lhs.r + rhs.r, g: lhs.g + rhs.g, b: lhs.b + rhs.b)
    }
}

@MainActor
final class AudioVisualizerBank: ObservableObject {
    @Published var bassWeight: Double = 1.35
    @Published var midWeight: Double = 1.0
    @Published var trebleWeight: Double = 1.0

    private var waterfallRows: [[RGBPixel]] = Array(repeating: Array(repeating: .black, count: 64), count: 64)
    private var idlePhase: Float = 0

    func makeFramebuffer(kind: VisualizerKind, analysis: AudioAnalysisSnapshot) -> [RGBPixel] {
        if analysis.peak < 0.0005 && analysis.rms < 0.0005 {
            return idlePattern()
        }

        switch kind {
        case .spectrumBars:
            return spectrumBars(analysis)
        case .oscilloscope:
            return oscilloscope(analysis)
        case .bassGlow:
            return bassGlow(analysis)
        case .vuMeter:
            return vuMeter(analysis)
        case .stereoMeter:
            return stereoMeter(analysis)
        case .waterfall:
            return waterfall(analysis)
        case .radialSpectrum:
            return radialSpectrum(analysis)
        case .debugBins:
            return debugBins(analysis)
        }
    }

    private func spectrumBars(_ analysis: AudioAnalysisSnapshot) -> [RGBPixel] {
        var fb = blank()
        for x in 0..<64 {
            let binStart = x * analysis.spectrum.count / 64
            let binEnd = max(binStart + 1, (x + 1) * analysis.spectrum.count / 64)
            let value = analysis.spectrum[binStart..<binEnd].reduce(0, +) / Float(binEnd - binStart)
            let height = min(63, Int(value * 63))
            for y in 0...height {
                let yy = 63 - y
                fb[index(x, yy)] = heatColor(Float(y) / 63, intensity: value)
            }
        }
        addBandAccents(&fb, analysis: analysis)
        return fb
    }

    private func oscilloscope(_ analysis: AudioAnalysisSnapshot) -> [RGBPixel] {
        var fb = blank()
        let waveform = analysis.oscilloscopeWaveform
        var previousY: Int?

        for x in 0..<64 {
            let sampleIndex = x * waveform.count / 64
            let sample = max(-1, min(1, waveform[sampleIndex]))
            let y = Int((1 - (sample * 0.48 + 0.5)) * 63)

            if let previousY {
                let start = min(previousY, y)
                let end = max(previousY, y)
                for yy in start...end {
                    plotWavePixel(&fb, x: x, y: yy, core: yy == y)
                }
            } else {
                plotWavePixel(&fb, x: x, y: y, core: true)
            }

            previousY = y
        }

        let center = 32
        for x in 0..<64 where fb[index(x, center)].r == 0 {
            fb[index(x, center)] = RGBPixel(r: 0.02, g: 0.08, b: 0.06)
        }
        return fb
    }

    private func bassGlow(_ analysis: AudioAnalysisSnapshot) -> [RGBPixel] {
        var fb = blank()
        let bass = min(1, analysis.bands.bass * Float(bassWeight) + analysis.bands.subBass)
        let mids = min(1, analysis.bands.mids * Float(midWeight))
        for y in 0..<64 {
            for x in 0..<64 {
                let dx = Float(x - 31)
                let dy = Float(y - 31)
                let radius = sqrt(dx * dx + dy * dy) / 45
                let pulse = max(0, 1 - radius) * bass
                let shimmer = sin(Float(x + y) * 0.23 + analysis.envelope * 8) * 0.04 + 0.04
                fb[index(x, y)] = RGBPixel(r: pulse * 1.0 + mids * 0.08,
                                            g: pulse * 0.22 + shimmer,
                                            b: pulse * 0.04 + mids * 0.35)
            }
        }
        return fb
    }

    private func vuMeter(_ analysis: AudioAnalysisSnapshot) -> [RGBPixel] {
        var fb = blank()
        let height = Int(min(1, analysis.rms * 4) * 64)
        for y in 0..<height {
            let color = heatColor(Float(y) / 63, intensity: 1)
            for x in 18..<46 {
                fb[index(x, 63 - y)] = color
            }
        }
        return fb
    }

    private func stereoMeter(_ analysis: AudioAnalysisSnapshot) -> [RGBPixel] {
        var fb = blank()
        let left = Int(min(1, analysis.stereo.left * 2.5) * 64)
        let right = Int(min(1, analysis.stereo.right * 2.5) * 64)
        for y in 0..<left {
            for x in 10..<26 { fb[index(x, 63 - y)] = RGBPixel(r: 0.1, g: 0.7, b: 1.0) }
        }
        for y in 0..<right {
            for x in 38..<54 { fb[index(x, 63 - y)] = RGBPixel(r: 1.0, g: 0.35, b: 0.15) }
        }
        return fb
    }

    private func waterfall(_ analysis: AudioAnalysisSnapshot) -> [RGBPixel] {
        let row = (0..<64).map { x in
            heatColor(analysis.spectrum[x * analysis.spectrum.count / 64], intensity: 1)
        }
        waterfallRows.removeLast()
        waterfallRows.insert(row, at: 0)
        return waterfallRows.flatMap { $0 }
    }

    private func radialSpectrum(_ analysis: AudioAnalysisSnapshot) -> [RGBPixel] {
        var fb = blank()
        let center = Float(31.5)
        for y in 0..<64 {
            for x in 0..<64 {
                let dx = Float(x) - center
                let dy = Float(y) - center
                let angle = atan2(dy, dx) + .pi
                let bin = min(analysis.spectrum.count - 1, Int(angle / (2 * .pi) * Float(analysis.spectrum.count)))
                let radius = sqrt(dx * dx + dy * dy)
                let target = analysis.spectrum[bin] * 31
                let edge = max(0, 1 - abs(radius - target) / 3)
                fb[index(x, y)] = RGBPixel(r: edge * 0.3, g: edge * 0.9, b: edge)
            }
        }
        return fb
    }

    private func debugBins(_ analysis: AudioAnalysisSnapshot) -> [RGBPixel] {
        var fb = blank()
        for bin in 0..<min(128, analysis.spectrum.count) {
            let x = bin % 64
            let yBase = bin < 64 ? 31 : 63
            let height = Int(analysis.spectrum[bin] * 30)
            for y in 0...height {
                fb[index(x, max(0, yBase - y))] = RGBPixel(r: 0.8, g: 0.8, b: 0.9)
            }
        }
        return fb
    }

    private func idlePattern() -> [RGBPixel] {
        idlePhase += 0.035
        var fb = blank()
        for y in 0..<64 {
            for x in 0..<64 {
                let xf = Float(x)
                let yf = Float(y)
                let wave = sin((xf * 0.22) + idlePhase) * 0.5 + 0.5
                let diagonal = sin(((xf + yf) * 0.12) - idlePhase * 1.7) * 0.5 + 0.5
                let grid = (x % 8 == 0 || y % 8 == 0) ? Float(0.10) : Float(0.0)
                fb[index(x, y)] = RGBPixel(r: 0.015 + diagonal * 0.10 + grid,
                                            g: 0.035 + wave * 0.16 + grid,
                                            b: 0.05 + (1 - wave) * 0.12 + grid)
            }
        }

        for x in 0..<64 {
            fb[index(x, 31)] = RGBPixel(r: 0.0, g: 0.7, b: 0.55)
            fb[index(x, 32)] = RGBPixel(r: 0.0, g: 0.35, b: 0.28)
        }
        return fb
    }

    private func addBandAccents(_ fb: inout [RGBPixel], analysis: AudioAnalysisSnapshot) {
        let bandValues: [Float] = [
            analysis.bands.subBass * Float(bassWeight),
            analysis.bands.bass * Float(bassWeight),
            analysis.bands.lowMids * Float(midWeight),
            analysis.bands.mids * Float(midWeight),
            analysis.bands.upperMids * Float(trebleWeight),
            analysis.bands.treble * Float(trebleWeight)
        ]
        for (band, value) in bandValues.enumerated() {
            let start = band * 10 + 2
            for x in start..<min(64, start + 8) {
                fb[index(x, 0)] = heatColor(value, intensity: value)
            }
        }
    }

    private func blank() -> [RGBPixel] {
        Array(repeating: .black, count: 64 * 64)
    }

    private func index(_ x: Int, _ y: Int) -> Int {
        y * 64 + x
    }

    private func plotWavePixel(_ fb: inout [RGBPixel], x: Int, y: Int, core: Bool) {
        for dy in -1...1 {
            let yy = min(63, max(0, y + dy))
            let amount: Float = core && dy == 0 ? 1.0 : 0.38
            fb[index(x, yy)] = RGBPixel(r: 0.04 * amount,
                                         g: 0.95 * amount,
                                         b: 0.72 * amount)
        }
    }

    private func heatColor(_ value: Float, intensity: Float) -> RGBPixel {
        let v = max(0, min(1, value))
        let i = max(0, min(1, intensity))
        return RGBPixel(r: min(1, v * 1.8) * i,
                        g: max(0, 1 - abs(v - 0.55) * 1.9) * i,
                        b: max(0, 1 - v * 1.2) * i)
    }
}
