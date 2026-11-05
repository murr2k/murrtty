// HLSL port of glsl/common.glsl for murrtty's Direct3D 11 renderer
// (roadmap 7.8). Every program file is compiled with this text before it.
// Keep the math as the GLSL has it: the frames were OpenGL's pixel by
// pixel (render-parity, until murrtty's OpenGL renderer retired), as
// GTK's app draws them.

//----------------------------------------------------------------------------//
// Global Uniforms (b1, as OpenGL's binding 1 and Metal's buffer 1)
//----------------------------------------------------------------------------//
// HLSL's cbuffer packing gives the same offsets as std140 here (the float4
// starts on 96), and its matrices are column-major as GLSL's are, so
// mul(projection_matrix, v) is GLSL's projection_matrix * v.
cbuffer Globals : register(b1) {
    float4x4 projection_matrix;
    float2 screen_size;
    float2 cell_size;
    uint grid_size_packed_2u16;
    float4 grid_padding;
    uint padding_extend;
    float min_contrast;
    uint cursor_pos_packed_2u16;
    uint cursor_color_packed_4u8;
    uint bg_color_packed_4u8;
    uint bools;
};

// Bools
static const uint CURSOR_WIDE = 1u;
static const uint USE_DISPLAY_P3 = 2u;
static const uint USE_LINEAR_BLENDING = 4u;
static const uint USE_LINEAR_CORRECTION = 8u;

// Padding extend enum
static const uint EXTEND_LEFT = 1u;
static const uint EXTEND_RIGHT = 2u;
static const uint EXTEND_UP = 4u;
static const uint EXTEND_DOWN = 8u;

//----------------------------------------------------------------------------//
// Functions for Unpacking Values
//----------------------------------------------------------------------------//

uint4 unpack4u8(uint packed_value) {
    return uint4(
        (packed_value >> 0) & 0xFFu,
        (packed_value >> 8) & 0xFFu,
        (packed_value >> 16) & 0xFFu,
        (packed_value >> 24) & 0xFFu
    );
}

uint2 unpack2u16(uint packed_value) {
    return uint2(
        (packed_value >> 0) & 0xFFFFu,
        (packed_value >> 16) & 0xFFFFu
    );
}

//----------------------------------------------------------------------------//
// Color Functions
//----------------------------------------------------------------------------//

// Takes colors in linear RGB space.
float luminance(float3 color) {
    return dot(color, float3(0.2126f, 0.7152f, 0.0722f));
}

// https://www.w3.org/TR/2008/REC-WCAG20-20081211/#contrast-ratiodef
float contrast_ratio(float3 color1, float3 color2) {
    float luminance1 = luminance(color1) + 0.05;
    float luminance2 = luminance(color2) + 0.05;
    return max(luminance1, luminance2) / min(luminance1, luminance2);
}

// The fg if its contrast with bg reaches min_ratio, else white or black,
// whichever contrasts more.
float4 contrasted_color(float min_ratio, float4 fg, float4 bg) {
    float ratio = contrast_ratio(fg.rgb, bg.rgb);
    if (ratio < min_ratio) {
        float white_ratio = contrast_ratio(float3(1.0, 1.0, 1.0), bg.rgb);
        float black_ratio = contrast_ratio(float3(0.0, 0.0, 0.0), bg.rgb);
        if (white_ratio > black_ratio) {
            return float4(1.0, 1.0, 1.0, 1.0);
        } else {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
    }

    return fg;
}

// Converts a color from sRGB gamma encoding to linear.
float4 linearize(float4 srgb) {
    bool3 cutoff = srgb.rgb <= float3(0.04045, 0.04045, 0.04045);
    float3 higher = pow((srgb.rgb + float3(0.055, 0.055, 0.055)) / float3(1.055, 1.055, 1.055), float3(2.4, 2.4, 2.4));
    float3 lower = srgb.rgb / float3(12.92, 12.92, 12.92);

    return float4(cutoff ? lower : higher, srgb.a);
}
float linearize(float v) {
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
}

// Converts a color from linear to sRGB gamma encoding.
float4 unlinearize(float4 linear_color) {
    bool3 cutoff = linear_color.rgb <= float3(0.0031308, 0.0031308, 0.0031308);
    float3 higher = pow(linear_color.rgb, float3(1.0 / 2.4, 1.0 / 2.4, 1.0 / 2.4)) * float3(1.055, 1.055, 1.055) - float3(0.055, 0.055, 0.055);
    float3 lower = linear_color.rgb * float3(12.92, 12.92, 12.92);

    return float4(cutoff ? lower : higher, linear_color.a);
}
float unlinearize(float v) {
    return v <= 0.0031308 ? v * 12.92 : pow(v, 1.0 / 2.4) * 1.055 - 0.055;
}

// Load a 4 byte RGBA non-premultiplied color, linearized if `linear_out`,
// premultiplied by its alpha.
float4 load_color(uint4 in_color, bool linear_out) {
    // 0 .. 255 -> 0.0 .. 1.0
    float4 color = float4(in_color) / float4(255.0f, 255.0f, 255.0f, 255.0f);

    // Linearize if necessary.
    if (linear_out) color = linearize(color);

    // Premultiply our color by its alpha.
    color.rgb *= color.a;

    return color;
}

//----------------------------------------------------------------------------//
// The full-screen triangle (glsl/full_screen.v.glsl)
//----------------------------------------------------------------------------//
// z is 0: Direct3D clips below 0 (GLSL used 1, inside GL's -1 to 1).
float4 full_screen_vs(uint vid : SV_VertexID) : SV_Position {
    float4 position;
    position.x = (vid == 2u) ? 3.0 : -1.0;
    position.y = (vid == 0u) ? -3.0 : 1.0;
    position.z = 0.0;
    position.w = 1.0;
    return position;
}

// GLSL's mod (x - y * floor(x / y)); HLSL's fmod truncates instead.
float2 glsl_mod(float2 x, float2 y) {
    return x - y * floor(x / y);
}
