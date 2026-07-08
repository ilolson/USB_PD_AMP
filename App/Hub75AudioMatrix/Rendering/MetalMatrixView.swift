import MetalKit
import SwiftUI

enum RendererMode: String, CaseIterable, Identifiable {
    case simple2D
    case realisticLens
    case meshObjectLED
    case rayTracedPreview

    var id: String { rawValue }

    var label: String {
        switch self {
        case .simple2D: "Simple 2D"
        case .realisticLens: "Realistic LED lens"
        case .meshObjectLED: "Mesh/object LED"
        case .rayTracedPreview: "Ray-traced preview"
        }
    }
}

struct MetalMatrixView: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> MetalRenderer {
        MetalRenderer(model: model)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColor(red: 0.005, green: 0.006, blue: 0.008, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.delegate = context.coordinator
        context.coordinator.attach(view: view)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.model = model
    }
}
