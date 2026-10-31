//
//  DSScreenShaders.metal
//  eDuo
//
//  Native presentation of the two DS framebuffers (256x192 BGRA). One fullscreen
//  triangle per screen; the fragment shader letterboxes (aspect fit), samples
//  nearest or bilinear and draws the scanline overlay. Everything happens in the
//  encoded (gamma) values, exactly like the Core Animation layers it replaces
//  (magnificationFilter + a tiled 18 % black CALayer).
//

#include <metal_stdlib>
using namespace metal;

struct DSUniforms
{
    float2 rectOrigin;   // top-left of the picture inside the drawable, in pixels
    float2 rectSize;     // size of the picture, in pixels
    float  scale;        // pixels per point (the scanline tile is 1 pt tall rows)
    float  scanAlpha;    // 0 = no scanlines, else alpha of the dark rows
    uint   nearest;      // 1 = nearest neighbour, 0 = bilinear
    uint   pad;
    float2 layerShift;   // where the layer's own origin sits relative to the drawable origin, in pixels
    float4 background;   // letterbox colour
};

struct DSVertexOut { float4 position [[position]]; };

vertex DSVertexOut dsScreenVertex(uint vid [[vertex_id]])
{
    float2 p = float2((vid << 1) & 2, vid & 2);
    DSVertexOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

fragment float4 dsScreenFragment(DSVertexOut in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 constant DSUniforms &u [[buffer(0)]])
{
    float2 p = in.position.xy;
    float2 uv = (p - u.rectOrigin) / u.rectSize;
    float3 c = u.background.rgb;
    if (all(uv >= 0.0) && all(uv < 1.0))
    {
        if (u.nearest != 0)
        {
            int2 size = int2(src.get_width(), src.get_height());
            int2 t = clamp(int2(floor(uv * float2(size))), int2(0), size - 1);
            c = src.read(uint2(t)).rgb;
        }
        else
        {
            constexpr sampler s(filter::linear, address::clamp_to_edge, coord::normalized);
            c = src.sample(s, uv).rgb;
        }
    }
    // Scanlines: rows of 1 pt, every second one darkened (black over the whole view). The legacy
    // tiled CALayer pattern comes out with its dark row FIRST (CG flips the tile), so row 0 is dark.
    if (u.scanAlpha > 0.0)
    {
        // The pattern is anchored at the layer's own (fractional) origin, so a pixel row can be
        // partly dark: coverage of [y0, y0+1) by the dark bands [2k*s, (2k+1)*s).
        float y0 = floor(p.y) - u.layerShift.y;
        float period = 2.0 * u.scale;
        float c0 = floor(y0 / period) * u.scale + clamp(fmod(y0, period) + (y0 < 0 ? period : 0), 0.0, u.scale);
        float y1 = y0 + 1.0;
        float c1 = floor(y1 / period) * u.scale + clamp(fmod(y1, period) + (y1 < 0 ? period : 0), 0.0, u.scale);
        c *= 1.0 - u.scanAlpha * clamp(c1 - c0, 0.0, 1.0);
    }
    return float4(c, 1.0);
}
