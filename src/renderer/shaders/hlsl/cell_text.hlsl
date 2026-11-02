// glsl/cell_text.v.glsl and cell_text.f.glsl.

// The atlases are sampled at pixel coordinates with nearest filtering,
// as OpenGL's rectangle textures: Load at floor(coordinate).
Texture2D<float4> atlas_grayscale : register(t0);
Texture2D<float4> atlas_color : register(t1);

// The renderer's storage buffer 1.
StructuredBuffer<uint> bg_colors : register(t2);

// Values `atlas` can take.
static const uint ATLAS_GRAYSCALE = 0u;
static const uint ATLAS_COLOR = 1u;

// Masks for the `glyph_bools` attribute
static const uint NO_MIN_CONTRAST = 1u;
static const uint IS_CURSOR_GLYPH = 2u;

// shaders.CellText, attribute by attribute (Pipeline's input layout).
struct VsIn {
    uint2 glyph_pos : ATTR0;
    uint2 glyph_size : ATTR1;
    int2 bearings : ATTR2;
    uint2 grid_pos : ATTR3;
    uint4 color : ATTR4;
    uint atlas : ATTR5;
    uint glyph_bools : ATTR6;
    uint vid : SV_VertexID;
};

struct VsOut {
    float4 position : SV_Position;
    nointerpolation uint atlas : ATLAS;
    nointerpolation float4 color : COLOR0;
    nointerpolation float4 bg_color : COLOR1;
    float2 tex_coord : TEXCOORD0;
};

VsOut vs_main(VsIn input) {
    VsOut output;
    uint2 grid_size = unpack2u16(grid_size_packed_2u16);
    uint2 cursor_pos = unpack2u16(cursor_pos_packed_2u16);
    bool cursor_wide = (bools & CURSOR_WIDE) != 0u;
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0u;

    // Convert the grid x, y into world space x, y by accounting for cell size
    float2 cell_pos = cell_size * float2(input.grid_pos);

    uint vid = input.vid;

    // A triangle strip of 4 vertices draws the quad:
    // 0 = top-left (0, 0), 1 = top-right (1, 0),
    // 2 = bot-left (0, 1), 3 = bot-right (1, 1).
    float2 corner;
    corner.x = float(vid == 1u || vid == 3u);
    corner.y = float(vid == 2u || vid == 3u);

    output.atlas = input.atlas;

    float2 size = float2(input.glyph_size);
    float2 offset = float2(input.bearings);

    offset.y = cell_size.y - offset.y;

    cell_pos = cell_pos + size * corner + offset;
    output.position = mul(projection_matrix, float4(cell_pos.x, cell_pos.y, 0.0f, 1.0f));

    // In pixels, not normalized.
    output.tex_coord = float2(input.glyph_pos) + float2(input.glyph_size) * corner;

    // Always linear, for the minimum contrast.
    output.color = load_color(input.color, true);
    output.bg_color = load_color(
        unpack4u8(bg_colors[input.grid_pos.y * grid_size.x + input.grid_pos.x]),
        true
    );
    // Blend it with the global bg color
    float4 global_bg = load_color(
        unpack4u8(bg_color_packed_4u8),
        true
    );
    output.bg_color += global_bg * float4(1.0 - output.bg_color.a, 1.0 - output.bg_color.a, 1.0 - output.bg_color.a, 1.0 - output.bg_color.a);

    if (min_contrast > 1.0f && (input.glyph_bools & NO_MIN_CONTRAST) == 0u) {
        output.color = contrasted_color(min_contrast, output.color, output.bg_color);
    }

    // Check if current position is under cursor (including wide cursor)
    bool is_cursor_pos = ((input.grid_pos.x == cursor_pos.x) || (cursor_wide && (input.grid_pos.x == (cursor_pos.x + 1u)))) && (input.grid_pos.y == cursor_pos.y);

    // The cursor's cell, but not the cursor glyph itself: its color.
    if ((input.glyph_bools & IS_CURSOR_GLYPH) == 0u && is_cursor_pos) {
        output.color = load_color(unpack4u8(cursor_color_packed_4u8), use_linear_blending);
    }

    return output;
}

float4 ps_main(VsOut input) : SV_Target {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0u;
    bool use_linear_correction = (bools & USE_LINEAR_CORRECTION) != 0u;
    int3 texel = int3(int2(floor(input.tex_coord)), 0);

    if (input.atlas == ATLAS_COLOR) {
        // Color glyphs are premultiplied linear colors (the sRGB view
        // decodes them).
        float4 color = atlas_color.Load(texel);

        if (use_linear_blending) {
            return color;
        }

        color.rgb /= float3(color.a, color.a, color.a);
        color = unlinearize(color);
        color.rgb *= float3(color.a, color.a, color.a);

        return color;
    }

    // Grayscale (and anything else, as the GLSL's default).
    {
        // Our input color is always linear.
        float4 color = input.color;

        // Without linear blending, gamma-encode it again (the alpha is
        // premultiplied, so divide it out and back).
        if (!use_linear_blending) {
            color.rgb /= float3(color.a, color.a, color.a);
            color = unlinearize(color);
            color.rgb *= float3(color.a, color.a, color.a);
        }

        // Fetch our alpha mask for this pixel.
        float a = atlas_grayscale.Load(texel).r;

        // Linear blending weight correction (see the GLSL).
        if (use_linear_correction) {
            float4 bg = input.bg_color;
            float fg_l = luminance(color.rgb);
            float bg_l = luminance(bg.rgb);
            if (abs(fg_l - bg_l) > 0.001) {
                float blend_l = linearize(unlinearize(fg_l) * a + unlinearize(bg_l) * (1.0 - a));
                a = clamp((blend_l - bg_l) / (fg_l - bg_l), 0.0, 1.0);
            }
        }

        color *= a;

        return color;
    }
}
