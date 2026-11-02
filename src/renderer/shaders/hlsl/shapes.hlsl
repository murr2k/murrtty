// murrtty's shapes over the frame (win32_present.Overlay: the dimming, the
// scrollbar, progress, the bars' shade), as OpenGL.zig's overlay program
// draws them, one instance per rectangle. Compiled without common.hlsl.

cbuffer Shapes : register(b0) {
    float2 window_size;
    float2 _pad;
};

struct VsIn {
    // x, y, width, height in window pixels from the top left.
    float4 rect : ATTR0;
    // Premultiplied sRGB.
    float4 color : ATTR1;
    uint vid : SV_VertexID;
};

struct VsOut {
    float4 position : SV_Position;
    nointerpolation float4 color : COLOR0;
};

// Two triangles covering the rect (vertices 0 to 5).
VsOut vs_main(VsIn input) {
    VsOut output;
    uint v = input.vid;
    float2 corner = float2((v == 1u || v == 2u || v == 4u) ? 1.0 : 0.0,
                           (v == 2u || v == 4u || v == 5u) ? 1.0 : 0.0);
    float2 px = input.rect.xy + corner * input.rect.zw;
    output.position = float4(px.x / window_size.x * 2.0 - 1.0, 1.0 - px.y / window_size.y * 2.0, 0.0, 1.0);
    output.color = input.color;
    return output;
}

float4 ps_main(VsOut input) : SV_Target {
    return input.color;
}
