import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                MetalMatrixView(model: model)
                MatrixOutputView(model: model)
            }
            .background(Color.black)
            .frame(minWidth: 720, minHeight: 720)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AudioPanel()
                    VisualizerPanel()
                    PanelSettingsView()
                    RendererSettingsView()
                    TimingDiagnosticsView()
                    GPIOTraceSummaryView()
                }
                .padding(18)
                .frame(width: 360, alignment: .topLeading)
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }
}

private struct AudioPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GroupBox("System Audio") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button(model.audioCapture.isCapturing ? "Stop Capture" : "Start Capture") {
                        Task {
                            if model.audioCapture.isCapturing {
                                await model.audioCapture.stop()
                            } else {
                                await model.audioCapture.start()
                            }
                        }
                    }
                    Spacer()
                    StatusPill(text: model.audioCapture.statusText,
                               color: model.audioCapture.isCapturing ? .green : .secondary)
                }

                Toggle("Exclude this app's audio", isOn: $model.audioCapture.excludesCurrentProcessAudio)
                LabeledSlider("Input gain", value: $model.analyzer.settings.inputGain, range: 0.1...8.0)
                Toggle("Automatic gain", isOn: $model.analyzer.settings.automaticGain)
                LabeledSlider("Smoothing", value: $model.analyzer.settings.smoothing, range: 0.0...0.95)
                LabeledSlider("Noise floor", value: $model.analyzer.settings.noiseFloorDB, range: -90.0...(-20.0))

                Picker("FFT size", selection: $model.analyzer.settings.fftSize) {
                    Text("512").tag(512)
                    Text("1024").tag(1024)
                    Text("2048").tag(2048)
                    Text("4096").tag(4096)
                }

                Picker("Window", selection: $model.analyzer.settings.windowFunction) {
                    ForEach(WindowFunction.allCases) { window in
                        Text(window.label).tag(window)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct VisualizerPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GroupBox("Visualizer") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Mode", selection: $model.visualizer) {
                    ForEach(VisualizerKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                Toggle("Show scanned HUB75 output", isOn: $model.showScannedOutput)
                if model.visualizer == .oscilloscope {
                    Toggle("Low-pass oscilloscope", isOn: $model.analyzer.settings.waveformLowPassEnabled)
                    LabeledSlider("Low-pass cutoff", value: $model.analyzer.settings.waveformLowPassHz, range: 40.0...1200.0)
                        .disabled(!model.analyzer.settings.waveformLowPassEnabled)
                }
                LabeledSlider("Bass weight", value: $model.visualizerBank.bassWeight, range: 0.1...3.0)
                LabeledSlider("Mid weight", value: $model.visualizerBank.midWeight, range: 0.1...3.0)
                LabeledSlider("Treble weight", value: $model.visualizerBank.trebleWeight, range: 0.1...3.0)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct PanelSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GroupBox("HUB75 Panel") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledSlider("Brightness", value: $model.panelSimulator.settings.brightness, range: 0.0...1.5)
                LabeledSlider("Gamma", value: $model.panelSimulator.settings.gamma, range: 1.0...3.2)
                Stepper("Bit depth: \(model.panelSimulator.settings.bitDepth)", value: $model.panelSimulator.settings.bitDepth, in: 1...8)
                LabeledSlider("Scan rate", value: $model.panelSimulator.settings.scanRateHz, range: 120.0...6000.0)
                Toggle("OE active low", isOn: $model.panelSimulator.settings.oeActiveLow)
                Toggle("LAT rising edge", isOn: $model.panelSimulator.settings.latRisingEdge)
                Toggle("Serpentine row order", isOn: $model.panelSimulator.settings.serpentineRows)
                LabeledSlider("Ghosting", value: $model.panelSimulator.settings.ghosting, range: 0.0...0.35)
                LabeledSlider("LED bleed", value: $model.panelSimulator.settings.ledBleed, range: 0.0...0.4)
                LabeledSlider("Temporal exposure", value: $model.panelSimulator.settings.temporalExposure, range: 0.05...1.0)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct RendererSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GroupBox("Renderer") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Mode", selection: $model.rendererMode) {
                    ForEach(RendererMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                LabeledSlider("Bloom/glow", value: $model.timingDiagnostics.renderSettings.glowAmount, range: 0.0...1.0)
                LabeledSlider("Camera angle", value: $model.timingDiagnostics.renderSettings.cameraAngle, range: -35.0...35.0)
                LabeledSlider("Pixel pitch", value: $model.timingDiagnostics.renderSettings.pixelPitch, range: 0.7...1.35)
                LabeledSlider("Bezel depth", value: $model.timingDiagnostics.renderSettings.bezelDepth, range: 0.0...1.0)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct TimingDiagnosticsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GroupBox("Timing Diagnostics") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                DiagnosticRow("Render FPS", model.timingDiagnostics.renderFPSText)
                DiagnosticRow("Refresh", model.panelSimulator.diagnostics.refreshRateText)
                DiagnosticRow("Row scan", model.panelSimulator.diagnostics.rowScanRateText)
                DiagnosticRow("OE duty", model.panelSimulator.diagnostics.oeDutyText)
                DiagnosticRow("Bit depth", "\(model.panelSimulator.settings.bitDepth)")
                DiagnosticRow("Audio latency", model.timingDiagnostics.audioLatencyText)
                DiagnosticRow("Ring buffer", model.audioCapture.ringBuffer.statusText)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct GPIOTraceSummaryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GroupBox("GPIO Trace") {
            VStack(alignment: .leading, spacing: 6) {
                Text("HUB75 mapping: R0 GPIO16, G0 GPIO17, B0 GPIO18, R1 GPIO19, G1 GPIO27, B1 GPIO29, A-E GPIO31-34/28, CLK GPIO35, LAT GPIO36, OE GPIO37.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Codec event rule: GPIO4/GPIO5 remain I2C SDA/SCL. Use GPIO6 for TAD5112 interrupt/event input, then read status over I2C.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct DiagnosticRow: View {
    let name: String
    let value: String

    init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }

    var body: some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

private struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) {
        self.title = title
        self._value = value
        self.range = range
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value.formatted(.number.precision(.fractionLength(2))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}
