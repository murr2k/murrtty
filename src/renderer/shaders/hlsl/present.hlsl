// murrtty's present pass (roadmap 7.8): the frame into the pane's swap
// chain, as OpenGL.zig's present_fragment does into the window's back
// buffer. Compiled without common.hlsl. The frame sits at the top left
// (SV_Position's origin, as Direct3D's texture rows run top down).

cbuffer Present : register(b0) {
    // The terminal background, linear or not as the frame is.
    float4 background;
    float2 frame_size;
    float background_alpha;
    // 1: transparent (the frame's own alpha, premultiplied sRGB out),
    // 2: frame_linear, 4: encode_out (sRGB encoded here).
    uint flags;
};

// Through an sRGB view: loads decode, as GL's texelFetch of an sRGB
// texture.
Texture2D<float4> frame : register(t0);

float4 vs_main(uint vid : SV_VertexID) : SV_Position {
    float2 pos = float2(vid == 2u ? 3.0 : -1.0, vid == 1u ? 3.0 : -1.0);
    return float4(pos, 0.0, 1.0);
}

// GLSL's mix(c * 12.92, 1.055 * pow(c, 1 / 2.4) - 0.055, step(0.0031308, c)).
float3 encode(float3 c) {
    bool3 low = c < float3(0.0031308, 0.0031308, 0.0031308);
    float3 lo = c * 12.92;
    float3 hi = 1.055 * pow(c, float3(1.0 / 2.4, 1.0 / 2.4, 1.0 / 2.4)) - 0.055;
    return low ? lo : hi;
}

float4 ps_main(float4 position : SV_Position) : SV_Target {
    bool transparent = (flags & 1u) != 0u;
    bool frame_linear = (flags & 2u) != 0u;
    bool encode_out = (flags & 4u) != 0u;
    int2 p = int2(position.xy);
    int2 size = int2(frame_size);
    // Beyond the frame (a resize), translucent, the background at its
    // opacity.
    float4 color = transparent ? float4(background.rgb, 1.0) * background_alpha : float4(0.0, 0.0, 0.0, 0.0);
    if (p.x >= 0 && p.y >= 0 && p.x < size.x && p.y < size.y) {
        color = frame.Load(int3(p, 0));
    }
    if (transparent) {
        // Premultiplied sRGB, written as is (through the plain view).
        float3 straight = color.a > 0.0 ? color.rgb / color.a : float3(0.0, 0.0, 0.0);
        if (frame_linear) straight = encode(straight);
        return float4(straight * color.a, color.a);
    }
    float4 out_color = color + background * (1.0 - color.a);
    if (encode_out) out_color.rgb = encode(saturate(out_color.rgb));
    return out_color;
}
