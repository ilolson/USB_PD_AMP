import Metal
import MetalKit
import QuartzCore
import simd

struct RendererUniforms {
    var viewportSize: SIMD2<Float>
    var glowAmount: Float
    var cameraAngle: Float
    var pixelPitch: Float
    var bezelDepth: Float
    var mode: UInt32
    var reserved: UInt32 = 0
}

@MainActor
final class MetalRenderer: NSObject, MTKViewDelegate {
    weak var model: AppModel?

    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var renderPipeline: MTLRenderPipelineState?
    private var meshRenderPipeline: MTLRenderPipelineState?
    private var computePipeline: MTLComputePipelineState?
    private var ledBuffer: MTLBuffer?
    private var uniformsBuffer: MTLBuffer?
    private var intensityTexture: MTLTexture?
    private var lastTime = CACurrentMediaTime()

    init(model: AppModel) {
        self.model = model
        self.device = MTLCreateSystemDefaultDevice()
        super.init()
    }

    func attach(view: MTKView) {
        if view.device == nil {
            view.device = device
        }
        device = view.device
        buildResources(colorPixelFormat: view.colorPixelFormat)
        buildDrawableResources(size: view.drawableSize)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        buildDrawableResources(size: size)
    }

    func draw(in view: MTKView) {
        guard let model,
              let commandQueue,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let ledBuffer,
              let uniformsBuffer else {
            return
        }

        let now = CACurrentMediaTime()
        lastTime = now
        let pixels = model.makeDisplayFrame(now: now)

        upload(pixels: pixels, to: ledBuffer)
        updateUniforms(view: view, buffer: uniformsBuffer, model: model)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        if let computePipeline, let intensityTexture {
            let encoder = commandBuffer.makeComputeCommandEncoder()
            encoder?.setComputePipelineState(computePipeline)
            encoder?.setBuffer(ledBuffer, offset: 0, index: 0)
            encoder?.setTexture(intensityTexture, index: 0)
            let width = computePipeline.threadExecutionWidth
            let threads = MTLSize(width: width, height: 1, depth: 1)
            let groups = MTLSize(width: (4096 + width - 1) / width, height: 1, depth: 1)
            encoder?.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
            encoder?.endEncoding()
        }

        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        if model.rendererMode == .meshObjectLED, let meshRenderPipeline {
            encoder?.setRenderPipelineState(meshRenderPipeline)
            encoder?.setMeshBuffer(ledBuffer, offset: 0, index: 0)
            encoder?.setMeshBuffer(uniformsBuffer, offset: 0, index: 1)
            encoder?.drawMeshThreadgroups(MTLSize(width: 64 * 64, height: 1, depth: 1),
                                          threadsPerObjectThreadgroup: MTLSize(width: 1, height: 1, depth: 1),
                                          threadsPerMeshThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        } else if let renderPipeline {
            encoder?.setRenderPipelineState(renderPipeline)
            encoder?.setVertexBuffer(ledBuffer, offset: 0, index: 0)
            encoder?.setVertexBuffer(uniformsBuffer, offset: 0, index: 1)
            encoder?.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 64 * 64)
        }
        encoder?.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { _ in
            Task { @MainActor in model.timingDiagnostics.markRendered() }
        }
        commandBuffer.commit()

    }

    private func buildResources(colorPixelFormat: MTLPixelFormat) {
        guard let device else { return }
        commandQueue = device.makeCommandQueue()
        ledBuffer = device.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride * 64 * 64,
                                      options: .storageModeShared)
        uniformsBuffer = device.makeBuffer(length: MemoryLayout<RendererUniforms>.stride,
                                           options: .storageModeShared)

        let library: MTLLibrary?
        do {
            if let defaultLibrary = device.makeDefaultLibrary() {
                library = defaultLibrary
            } else {
                library = try device.makeLibrary(source: Self.runtimeShaderSource, options: nil)
            }
        } catch {
            print("Metal shader library failed: \(error)")
            return
        }
        guard let library else {
            print("Metal shader library unavailable")
            return
        }
        if let vertex = library.makeFunction(name: "ledVertex"),
           let fragment = library.makeFunction(name: "ledFragment") {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            do {
                renderPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                print("Metal render pipeline failed: \(error)")
            }
        } else {
            print("Metal shader functions ledVertex/ledFragment unavailable")
        }

        if device.supportsFamily(.metal3),
           let mesh = library.makeFunction(name: "ledMesh"),
           let fragment = library.makeFunction(name: "ledFragment") {
            let descriptor = MTLMeshRenderPipelineDescriptor()
            descriptor.label = "LED mesh pipeline"
            descriptor.meshFunction = mesh
            descriptor.fragmentFunction = fragment
            descriptor.maxTotalThreadsPerMeshThreadgroup = 1
            descriptor.meshThreadgroupSizeIsMultipleOfThreadExecutionWidth = false
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            device.makeRenderPipelineState(descriptor: descriptor, options: []) { [weak self] pipeline, _, error in
                if let error {
                    print("Metal mesh render pipeline failed: \(error)")
                    return
                }
                guard let pipeline else { return }
                Task { @MainActor in
                    self?.meshRenderPipeline = pipeline
                }
            }
        }

        if let compute = library.makeFunction(name: "updateIntensityTexture") {
            do {
                computePipeline = try device.makeComputePipelineState(function: compute)
            } catch {
                print("Metal compute pipeline failed: \(error)")
            }
        }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                         width: 64,
                                                                         height: 64,
                                                                         mipmapped: false)
        textureDescriptor.usage = [.shaderRead, .shaderWrite]
        intensityTexture = device.makeTexture(descriptor: textureDescriptor)
    }

    private func buildDrawableResources(size: CGSize) {
        _ = size
    }

    private func upload(pixels: [RGBPixel], to buffer: MTLBuffer) {
        let pointer = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: 64 * 64)
        for i in 0..<min(pixels.count, 64 * 64) {
            pointer[i] = SIMD4<Float>(pixels[i].r, pixels[i].g, pixels[i].b, 1)
        }
    }

    private func updateUniforms(view: MTKView, buffer: MTLBuffer, model: AppModel) {
        let modeValue: UInt32
        switch model.rendererMode {
        case .simple2D:
            modeValue = 0
        case .realisticLens:
            modeValue = 1
        case .meshObjectLED:
            modeValue = 2
        case .rayTracedPreview:
            modeValue = 3
        }

        let uniforms = RendererUniforms(viewportSize: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
                                        glowAmount: Float(model.timingDiagnostics.renderSettings.glowAmount),
                                        cameraAngle: Float(model.timingDiagnostics.renderSettings.cameraAngle),
                                        pixelPitch: Float(model.timingDiagnostics.renderSettings.pixelPitch),
                                        bezelDepth: Float(model.timingDiagnostics.renderSettings.bezelDepth),
                                        mode: modeValue)
        buffer.contents().copyMemory(from: [uniforms], byteCount: MemoryLayout<RendererUniforms>.stride)
    }

    private static let runtimeShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct RendererUniforms {
        float2 viewportSize;
        float glowAmount;
        float cameraAngle;
        float pixelPitch;
        float bezelDepth;
        uint mode;
        uint reserved;
    };

    struct VertexOut {
        float4 position [[position]];
        float4 color;
        float2 local;
    };

    static VertexOut makeLEDVertex(uint ledID, float2 local, const device float4 *leds, constant RendererUniforms &uniforms) {
        uint x = ledID % 64;
        uint y = ledID / 64;
        float pitch = uniforms.pixelPitch;
        float ledRadius = 0.88 / 64.0 * pitch;
        float2 center = (float2(float(x), float(y)) + 0.5) / 64.0 * 2.0 - 1.0;
        center.y = -center.y;

        float perspective = 1.0 + sin(uniforms.cameraAngle * 0.01745329252) * center.y * 0.18;
        float2 position = center + local * ledRadius * perspective;

        VertexOut out;
        out.position = float4(position, 0.0, 1.0);
        out.local = local;

        float4 led = leds[ledID];
        float lens = 1.0;
        if (uniforms.mode > 0) {
            float squareDistance = max(abs(local.x), abs(local.y));
            lens = smoothstep(1.08, 0.18, squareDistance);
            led.rgb *= 0.35 + lens * 0.9;
        }
        if (uniforms.mode >= 2) {
            led.rgb += uniforms.glowAmount * led.rgb * 0.35;
        }
        if (uniforms.mode >= 3) {
            float reflection = max(0.0, 0.7 - length(local - float2(-0.35, -0.45)));
            led.rgb += reflection * 0.18;
        }

        out.color = float4(led.rgb, max(0.18, lens));
        return out;
    }

    kernel void updateIntensityTexture(const device float4 *leds [[buffer(0)]],
                                       texture2d<float, access::write> texture [[texture(0)]],
                                       uint id [[thread_position_in_grid]]) {
        if (id >= 4096) {
            return;
        }
        uint x = id % 64;
        uint y = id / 64;
        texture.write(float4(leds[id].rgb, 1.0), uint2(x, y));
    }

    vertex VertexOut ledVertex(uint vertexID [[vertex_id]],
                               uint instanceID [[instance_id]],
                               const device float4 *leds [[buffer(0)]],
                               constant RendererUniforms &uniforms [[buffer(1)]]) {
        constexpr float2 corners[6] = {
            float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
            float2(1.0, -1.0), float2(1.0, 1.0), float2(-1.0, 1.0)
        };

        uint x = instanceID % 64;
        uint y = instanceID / 64;
        float pitch = uniforms.pixelPitch;
        float ledRadius = 0.88 / 64.0 * pitch;
        float2 center = (float2(float(x), float(y)) + 0.5) / 64.0 * 2.0 - 1.0;
        center.y = -center.y;

        float perspective = 1.0 + sin(uniforms.cameraAngle * 0.01745329252) * center.y * 0.18;
        float2 position = center + corners[vertexID] * ledRadius * perspective;

        VertexOut out;
        out.position = float4(position, 0.0, 1.0);
        out.local = corners[vertexID];

        float4 led = leds[instanceID];
        float lens = 1.0;
        if (uniforms.mode > 0) {
            float radial = length(corners[vertexID]);
            lens = smoothstep(1.25, 0.15, radial);
            led.rgb *= 0.35 + lens * 0.9;
        }
        if (uniforms.mode >= 2) {
            led.rgb += uniforms.glowAmount * led.rgb * 0.35;
        }
        if (uniforms.mode >= 3) {
            float reflection = max(0.0, 0.7 - length(corners[vertexID] - float2(-0.35, -0.45)));
            led.rgb += reflection * 0.18;
        }

        out.color = float4(led.rgb, max(0.18, lens));
        return out;
    }

    [[mesh, max_total_threads_per_threadgroup(1)]]
    void ledMesh(uint ledID [[threadgroup_position_in_grid]],
                 const device float4 *leds [[buffer(0)]],
                 constant RendererUniforms &uniforms [[buffer(1)]],
                 mesh<VertexOut, void, 4, 2, topology::triangle> outMesh) {
        constexpr float2 corners[4] = {
            float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0)
        };

        outMesh.set_primitive_count(2);
        outMesh.set_vertex(0, makeLEDVertex(ledID, corners[0], leds, uniforms));
        outMesh.set_vertex(1, makeLEDVertex(ledID, corners[1], leds, uniforms));
        outMesh.set_vertex(2, makeLEDVertex(ledID, corners[2], leds, uniforms));
        outMesh.set_vertex(3, makeLEDVertex(ledID, corners[3], leds, uniforms));
        outMesh.set_index(0, 0);
        outMesh.set_index(1, 1);
        outMesh.set_index(2, 2);
        outMesh.set_index(3, 1);
        outMesh.set_index(4, 3);
        outMesh.set_index(5, 2);
    }

    fragment float4 ledFragment(VertexOut in [[stage_in]]) {
        float2 edge = abs(in.local);
        float squareDistance = max(edge.x, edge.y);
        float bevel = length(max(edge - 0.82, 0.0));
        float mask = smoothstep(1.02, 0.92, squareDistance);
        float face = 1.0 - smoothstep(0.72, 1.0, bevel);
        float glow = smoothstep(1.28, 0.72, squareDistance) * 0.20;
        float3 color = in.color.rgb * (mask * (0.78 + face * 0.22) + glow);
        return float4(color, max(mask, glow) * in.color.a);
    }
    """
}
