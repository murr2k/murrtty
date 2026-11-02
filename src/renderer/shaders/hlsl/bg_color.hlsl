// glsl/bg_color.f.glsl. Vertex shader: full_screen_vs.

float4 ps_main(float4 position : SV_Position) : SV_Target {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0u;

    return load_color(
        unpack4u8(bg_color_packed_4u8),
        use_linear_blending
    );
}
