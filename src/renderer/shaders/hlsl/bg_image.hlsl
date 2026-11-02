// glsl/bg_image.v.glsl and bg_image.f.glsl.

Texture2D<float4> image : register(t0);
SamplerState image_sampler : register(s0);

// 4 bits of info.
static const uint BG_IMAGE_POSITION = 15u;
static const uint BG_IMAGE_TL = 0u;
static const uint BG_IMAGE_TC = 1u;
static const uint BG_IMAGE_TR = 2u;
static const uint BG_IMAGE_ML = 3u;
static const uint BG_IMAGE_MC = 4u;
static const uint BG_IMAGE_MR = 5u;
static const uint BG_IMAGE_BL = 6u;
static const uint BG_IMAGE_BC = 7u;
static const uint BG_IMAGE_BR = 8u;

// 2 bits of info shifted 4.
static const uint BG_IMAGE_FIT = 3u << 4;
static const uint BG_IMAGE_CONTAIN = 0u << 4;
static const uint BG_IMAGE_COVER = 1u << 4;
static const uint BG_IMAGE_STRETCH = 2u << 4;
static const uint BG_IMAGE_NO_FIT = 3u << 4;

// 1 bit of info shifted 6.
static const uint BG_IMAGE_REPEAT = 1u << 6;

// shaders.BgImage, attribute by attribute.
struct VsIn {
    float in_opacity : ATTR0;
    uint info : ATTR1;
    uint vid : SV_VertexID;
};

struct VsOut {
    float4 position : SV_Position;
    nointerpolation float4 bg_color : COLOR0;
    nointerpolation float2 offset : OFFSET;
    nointerpolation float2 scale : SCALE;
    nointerpolation float opacity : OPACITY;
    nointerpolation uint repeat_image : REPEAT;
};

VsOut vs_main(VsIn input) {
    VsOut output;
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0u;

    output.position = full_screen_vs(input.vid);

    output.opacity = input.in_opacity;

    output.repeat_image = input.info & BG_IMAGE_REPEAT;

    uint width, height;
    image.GetDimensions(width, height);
    float2 tex_size = float2(width, height);

    float2 dest_size = tex_size;
    uint fit = input.info & BG_IMAGE_FIT;
    if (fit == BG_IMAGE_CONTAIN) {
        float scale = min(screen_size.x / tex_size.x, screen_size.y / tex_size.y);
        dest_size = tex_size * scale;
    } else if (fit == BG_IMAGE_COVER) {
        float scale = max(screen_size.x / tex_size.x, screen_size.y / tex_size.y);
        dest_size = tex_size * scale;
    } else if (fit == BG_IMAGE_STRETCH) {
        dest_size = screen_size;
    } else if (fit == BG_IMAGE_NO_FIT) {
        dest_size = tex_size;
    }

    float2 start = float2(0.0, 0.0);
    float2 mid = (screen_size - dest_size) / float2(2.0, 2.0);
    float2 end = screen_size - dest_size;

    float2 dest_offset = mid;
    uint position = input.info & BG_IMAGE_POSITION;
    if (position == BG_IMAGE_TL) {
        dest_offset = float2(start.x, start.y);
    } else if (position == BG_IMAGE_TC) {
        dest_offset = float2(mid.x, start.y);
    } else if (position == BG_IMAGE_TR) {
        dest_offset = float2(end.x, start.y);
    } else if (position == BG_IMAGE_ML) {
        dest_offset = float2(start.x, mid.y);
    } else if (position == BG_IMAGE_MC) {
        dest_offset = float2(mid.x, mid.y);
    } else if (position == BG_IMAGE_MR) {
        dest_offset = float2(end.x, mid.y);
    } else if (position == BG_IMAGE_BL) {
        dest_offset = float2(start.x, end.y);
    } else if (position == BG_IMAGE_BC) {
        dest_offset = float2(mid.x, end.y);
    } else if (position == BG_IMAGE_BR) {
        dest_offset = float2(end.x, end.y);
    }

    output.offset = dest_offset;
    output.scale = tex_size / dest_size;

    // A fully opaque bg color, its alpha apart: the fragment shader needs
    // them separately.
    uint4 u_bg_color = unpack4u8(bg_color_packed_4u8);
    output.bg_color = float4(load_color(
        uint4(u_bg_color.rgb, 255u),
        use_linear_blending
    ).rgb, float(u_bg_color.a) / 255.0);
    return output;
}

float4 ps_main(VsOut input) : SV_Target {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0u;

    float2 tex_coord = (input.position.xy - input.offset) * input.scale;

    uint width, height;
    image.GetDimensions(width, height);
    float2 tex_size = float2(width, height);

    // If we need to repeat the texture, wrap the coordinates.
    if (input.repeat_image != 0u) {
        tex_coord = glsl_mod(glsl_mod(tex_coord, tex_size) + tex_size, tex_size);
    }

    float4 rgba;
    if (any(tex_coord < float2(0.0, 0.0)) || any(tex_coord > tex_size)) {
        rgba = float4(0.0, 0.0, 0.0, 0.0);
    } else {
        rgba = image.Sample(image_sampler, tex_coord / tex_size);

        if (!use_linear_blending) {
            rgba = unlinearize(rgba);
        }

        rgba.rgb *= rgba.a;
    }

    // The configured opacity, capped where it would be fully opaque over
    // the background's alpha.
    rgba *= min(input.opacity, 1.0 / input.bg_color.a);

    // Blend it on to a fully opaque version of the background color.
    rgba += max(float4(0.0, 0.0, 0.0, 0.0), float4(input.bg_color.rgb, 1.0) * (1.0 - rgba.a));

    // Multiply everything by the background color alpha.
    rgba *= input.bg_color.a;

    return rgba;
}
