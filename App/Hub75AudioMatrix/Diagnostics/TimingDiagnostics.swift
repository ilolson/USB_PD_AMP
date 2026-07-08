import Foundation
import QuartzCore

struct RenderSettings {
    var glowAmount: Double = 0.28
    var cameraAngle: Double = 0
    var pixelPitch: Double = 1
    var bezelDepth: Double = 0.35
}

@MainActor
final class TimingDiagnostics: ObservableObject {
    @Published var renderSettings = RenderSettings()
    @Published private(set) var renderFPS: Double = 0
    @Published private(set) var audioLatencyMS: Double = 0

    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private var smoothedFrameTime: Double = 1.0 / 60.0

    var renderFPSText: String { "\(Int(renderFPS.rounded()))" }
    var audioLatencyText: String { "\(Int(audioLatencyMS.rounded())) ms" }

    func markRendered() {
        let now = CACurrentMediaTime()
        let dt = max(0.0001, now - lastFrameTime)
        smoothedFrameTime = smoothedFrameTime * 0.92 + dt * 0.08
        renderFPS = 1.0 / smoothedFrameTime
        lastFrameTime = now
    }

    func updateAudioLatency(bufferedFrames: Int, sampleRate: Double) {
        audioLatencyMS = Double(bufferedFrames) / sampleRate * 1000
    }
}
