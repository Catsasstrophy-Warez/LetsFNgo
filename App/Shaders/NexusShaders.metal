// RealityKit surface shaders for the digital twin. Compiled into the app's
// default Metal library; NexusRealityKit looks them up by name and falls
// back to physically based materials where custom materials aren't
// supported (the Simulator, previews).
#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

/// Cables and pipes: bands of light travel along the connector, showing the
/// direction of signal or flow.
[[visible]]
void nexusSignalFlow(realitykit::surface_parameters params) {
    float time = params.uniforms().time();
    float2 uv = params.geometry().uv0();
    half3 tint = half3(params.material_constants().base_color_tint());
    float band = smoothstep(0.75, 1.0, 0.5 + 0.5 * sin(uv.y * 40.0 - time * 6.0));
    params.surface().set_base_color(tint * 0.35h);
    params.surface().set_emissive_color(tint * half(band) * 1.5h);
    params.surface().set_roughness(0.35h);
    params.surface().set_metallic(0.6h);
}

/// Where observed and modeled values diverge: a slow pulse, so the first
/// divergence is visible at a glance (the card above says why, in words).
[[visible]]
void nexusAlertPulse(realitykit::surface_parameters params) {
    float time = params.uniforms().time();
    half3 tint = half3(params.material_constants().base_color_tint());
    half pulse = half(0.55 + 0.45 * sin(time * 3.0));
    params.surface().set_base_color(tint);
    params.surface().set_emissive_color(tint * pulse * 1.8h);
    params.surface().set_roughness(0.4h);
    params.surface().set_metallic(0.1h);
}
