#include <metal_stdlib>
using namespace metal;

/// One colored vertex, already positioned in chart space (not clip space —
/// the vertex function multiplies by the orthographic projection). Kept as a
/// flat position+color pair rather than per-instance attributes: candles,
/// wicks, the VWAP line, and the volume histogram are all generated as plain
/// triangles/lines on the CPU side whenever the visible window changes, so a
/// single generic pipeline handles every element in one draw call per pass.
struct ChartVertex {
    float2 position;
    float4 color;
};

struct ChartUniforms {
    float4x4 projection;
};

struct ChartVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex ChartVertexOut chart_vertex_main(
    uint vertexID [[vertex_id]],
    constant ChartVertex *vertices [[buffer(0)]],
    constant ChartUniforms &uniforms [[buffer(1)]]
) {
    ChartVertex v = vertices[vertexID];
    ChartVertexOut out;
    out.position = uniforms.projection * float4(v.position, 0.0, 1.0);
    out.color = v.color;
    return out;
}

fragment float4 chart_fragment_main(ChartVertexOut in [[stage_in]]) {
    return in.color;
}
