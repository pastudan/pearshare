#include <metal_stdlib>
using namespace metal;

// MARK: - Vertex shader
// Generates a fullscreen quad without a vertex buffer.
// Vertex indices 0-3 map to the four corners of clip space.

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut vertexPassthrough(uint vertexID [[vertex_id]]) {
    // Clip-space positions for a triangle strip covering the full screen
    constexpr float2 positions[4] = {
        float2(-1.0,  1.0),  // top-left
        float2( 1.0,  1.0),  // top-right
        float2(-1.0, -1.0),  // bottom-left
        float2( 1.0, -1.0),  // bottom-right
    };
    constexpr float2 texCoords[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0),
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

// MARK: - Fragment shader
// Converts biplanar YCbCr (420v) to BGRA for display.
// BT.709 coefficients (HD content from ScreenCaptureKit).

fragment float4 fragmentYCbCrToRGB(
    VertexOut in [[stage_in]],
    texture2d<float> yTexture  [[texture(0)]],
    texture2d<float> uvTexture [[texture(1)]]
) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    float y  = yTexture.sample(s, in.texCoord).r;
    float2 uv = uvTexture.sample(s, in.texCoord).rg;

    // Video range: Y is [16/255, 235/255], UV is [16/255, 240/255]
    y  = (y  - 16.0  / 255.0) * (255.0 / 219.0);
    float u = (uv.r - 128.0 / 255.0) * (255.0 / 224.0);
    float v = (uv.g - 128.0 / 255.0) * (255.0 / 224.0);

    // BT.709 matrix
    float r = y + 1.5748 * v;
    float g = y - 0.1873 * u - 0.4681 * v;
    float b = y + 1.8556 * u;

    return float4(r, g, b, 1.0);
}
