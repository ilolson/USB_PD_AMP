import SwiftUI

@main
struct Hub75AudioMatrixApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .frame(minWidth: 1180, minHeight: 760)
        }
        .windowStyle(.titleBar)
    }
}

@MainActor
final class AppModel: ObservableObject {
    var audioCapture = SystemAudioCapture()
    var analyzer = AudioAnalyzer()
    var visualizerBank = AudioVisualizerBank()
    var panelSimulator = Hub75PanelSimulator()
    var timingDiagnostics = TimingDiagnostics()

    @Published var visualizer: VisualizerKind = .oscilloscope
    @Published var rendererMode: RendererMode = .simple2D
    @Published var showScannedOutput = true

    private var lastDisplayFrameTime = CACurrentMediaTime()

    init() {
        analyzer.source = audioCapture.ringBuffer
    }

    func makeDisplayFrame(now: CFTimeInterval = CACurrentMediaTime()) -> [RGBPixel] {
        let delta = max(1.0 / 240.0, min(1.0 / 15.0, now - lastDisplayFrameTime))
        lastDisplayFrameTime = now

        let analysis = analyzer.analyze()
        let logical = visualizerBank.makeFramebuffer(kind: visualizer, analysis: analysis)
        panelSimulator.setFramebuffer(logical)
        return showScannedOutput ? panelSimulator.simulateOutput(deltaTime: delta) : panelSimulator.rawFramebuffer()
    }
}
