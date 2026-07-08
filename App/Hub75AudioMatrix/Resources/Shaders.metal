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
