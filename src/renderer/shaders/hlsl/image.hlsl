// glsl/image.v.glsl and image.f.glsl.

Texture2D<float4> image : register(t0);
SamplerState image_sampler : register(s0);

// shaders.Image, attribute by attribute.
struct VsIn {
    float2 grid_pos : ATTR0;
    float2 cell_offset : ATTR1;
    float4 source_rect : ATTR2;
    float2 dest_size : ATTR3;
    uint vid : SV_VertexID;
};

struct VsOut {
    float4 position : SV_Position;
    float2 tex_coord : TEXCOORD0;
};

VsOut vs_main(VsIn input) {
    VsOut output;
    uint vid = input.vid;

    // A triangle strip of 4 vertices draws the quad (see cell_text).
    float2 corner;
    corner.x = float(vid == 1u || vid == 3u);
    corner.y = float(vid == 2u || vid == 3u);

    // The texture coordinates start at our source x/y
    // and add the width/height depending on the corner.
    float2 tex_coord = input.source_rect.xy;
    tex_coord += input.source_rect.zw * corner;

    // Normalize the coordinates.
    uint width, height;
    image.GetDimensions(width, height);
    tex_coord /= float2(width, height);
    output.tex_coord = tex_coord;

    float2 image_pos = (cell_size * input.grid_pos) + input.cell_offset;
    image_pos += input.dest_size * corner;

    // z 0: the GLSL's 1 projects to -1, which Direct3D clips.
    output.position = mul(projection_matrix, float4(image_pos.xy, 0.0, 1.0));
    return output;
}

float4 ps_main(VsOut input) : SV_Target {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0u;

    float4 rgba = image.Sample(image_sampler, input.tex_coord);

    if (!use_linear_blending) {
        rgba = unlinearize(rgba);
    }

    rgba.rgb *= float3(rgba.a, rgba.a, rgba.a);

    return rgba;
}
