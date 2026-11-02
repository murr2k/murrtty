//! The Direct3D 11 renderer's programs (shaders/hlsl, ports of the GLSL)
//! and its pipeline set, as opengl/shaders.zig's.
const std = @import("std");
const Allocator = std.mem.Allocator;
const d3d11 = @import("d3d11");
const d3d = d3d11.d3d;

const Device = @import("Device.zig");
const Pipeline = @import("Pipeline.zig");
const gl_shaders = @import("../opengl/shaders.zig");

const log = std.log.scoped(.d3d11);

// The data the shaders take is OpenGL's, byte for byte.
pub const Uniforms = gl_shaders.Uniforms;
pub const CellText = gl_shaders.CellText;
pub const CellBg = gl_shaders.CellBg;
pub const Image = gl_shaders.Image;
pub const BgImage = gl_shaders.BgImage;

const common = @embedFile("../shaders/hlsl/common.hlsl");

pub const Source = struct {
    text: []const u8,
    vs: [:0]const u8,
    /// Empty: no pixel shader (the custom shaders bring theirs).
    ps: [:0]const u8,
};

fn withCommon(comptime file: []const u8) []const u8 {
    return common ++ "\n#line 1 \"" ++ file ++ "\"\n" ++ @embedFile("../shaders/hlsl/" ++ file);
}

pub const sources: std.EnumArray(Device.Program, Source) = .init(.{
    .bg_color = .{ .text = withCommon("bg_color.hlsl"), .vs = "full_screen_vs", .ps = "ps_main" },
    .cell_bg = .{ .text = withCommon("cell_bg.hlsl"), .vs = "full_screen_vs", .ps = "ps_main" },
    .cell_text = .{ .text = withCommon("cell_text.hlsl"), .vs = "vs_main", .ps = "ps_main" },
    .image = .{ .text = withCommon("image.hlsl"), .vs = "vs_main", .ps = "ps_main" },
    .bg_image = .{ .text = withCommon("bg_image.hlsl"), .vs = "vs_main", .ps = "ps_main" },
    .present = .{ .text = @embedFile("../shaders/hlsl/present.hlsl"), .vs = "vs_main", .ps = "ps_main" },
    .shapes = .{ .text = @embedFile("../shaders/hlsl/shapes.hlsl"), .vs = "vs_main", .ps = "ps_main" },
    .post = .{ .text = common, .vs = "full_screen_vs", .ps = "" },
});

/// The pipelines a frame draws with, as OpenGL's.
const pipeline_descs = .{
    .{ "bg_color", Device.Program.bg_color, null, Pipeline.Options.StepFunction.per_vertex, false },
    .{ "cell_bg", Device.Program.cell_bg, null, Pipeline.Options.StepFunction.per_vertex, true },
    .{ "cell_text", Device.Program.cell_text, CellText, Pipeline.Options.StepFunction.per_instance, true },
    .{ "image", Device.Program.image, Image, Pipeline.Options.StepFunction.per_instance, true },
    .{ "bg_image", Device.Program.bg_image, BgImage, Pipeline.Options.StepFunction.per_instance, true },
};

const PipelineCollection = struct {
    bg_color: Pipeline,
    cell_bg: Pipeline,
    cell_text: Pipeline,
    image: Pipeline,
    bg_image: Pipeline,
};

pub const Shaders = struct {
    pipelines: PipelineCollection,

    /// Custom shaders, each run on the previous one's output.
    post_pipelines: []const Pipeline,

    /// Set once deinited, so a second deinit does nothing.
    defunct: bool = false,

    pub const uninit: Shaders = .{
        .pipelines = undefined,
        .post_pipelines = &.{},
        .defunct = true,
    };

    pub fn init(
        alloc: Allocator,
        gpu: *d3d.Device,
        device: *Device,
        post_shaders: []const [:0]const u8,
    ) !Shaders {
        var pipelines: PipelineCollection = undefined;
        var made: usize = 0;
        errdefer inline for (pipeline_descs, 0..) |desc, i| {
            if (i < made) @field(pipelines, desc[0]).deinit();
        };
        inline for (pipeline_descs) |desc| {
            const code = try device.bytecode(desc[1]);
            @field(pipelines, desc[0]) = try Pipeline.init(gpu, desc[2], .{
                .vertex = code.vs,
                .pixel = code.ps,
                .step_fn = desc[3],
                .blending_enabled = desc[4],
            });
            made += 1;
        }

        // A custom shader that fails to build leaves them all out rather
        // than keeping the terminal from drawing.
        const post_pipelines: []const Pipeline = initPostPipelines(alloc, gpu, device, post_shaders) catch |err| err: {
            log.warn("error initializing postprocess shaders err={}", .{err});
            break :err &.{};
        };

        return .{
            .pipelines = pipelines,
            .post_pipelines = post_pipelines,
        };
    }

    pub fn deinit(self: *Shaders, alloc: Allocator) void {
        if (self.defunct) return;
        self.defunct = true;
        inline for (pipeline_descs) |desc| @field(self.pipelines, desc[0]).deinit();
        if (self.post_pipelines.len > 0) {
            for (self.post_pipelines) |p| p.deinit();
            alloc.free(self.post_pipelines);
        }
    }
};

/// The custom shaders (HLSL from shadertoy.zig), each drawn as a full
/// screen triangle.
fn initPostPipelines(
    alloc: Allocator,
    gpu: *d3d.Device,
    device: *Device,
    shaders: []const [:0]const u8,
) ![]const Pipeline {
    if (shaders.len == 0) return &.{};
    if (device.test_fail == .post) return error.CompileFailed;
    const vs = (try device.bytecode(.post)).vs;
    var i: usize = 0;
    var pipelines = try alloc.alloc(Pipeline, shaders.len);
    errdefer {
        for (pipelines[0..i]) |p| p.deinit();
        alloc.free(pipelines);
    }
    for (shaders) |source| {
        const ps = try Device.compileStage(alloc, source, "custom-shader", "main", "ps_5_0");
        defer alloc.free(ps);
        pipelines[i] = try Pipeline.init(gpu, null, .{ .vertex = vs, .pixel = ps });
        i += 1;
    }
    return pipelines;
}

test "custom shaders compile, OpenGL's coordinates and all" {
    const shadertoy = @import("../shadertoy.zig");
    const alloc = std.testing.allocator;
    // Every call shadertoy's hlsl_main wraps, and the CRT test shader.
    for ([_][]const u8{ @embedFile("../shaders/test_shadertoy_crt.glsl"),
        \\void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        \\    vec2 uv = fragCoord / iResolution.xy;
        \\    vec4 c = texture(iChannel0, uv) + texture(iChannel0, uv, 0.5) + texture2D(iChannel0, uv);
        \\    c += textureLod(iChannel0, uv, 0.0) + textureGrad(iChannel0, uv, dFdx(uv), dFdy(uv));
        \\    c += textureOffset(iChannel0, uv, ivec2(1, 2)) + texelFetch(iChannel0, ivec2(gl_FragCoord.xy), 0);
        \\    fragColor = c * dFdy(uv.y);
        \\}
        \\
    }) |shader| {
        var glsl: std.Io.Writer.Allocating = .init(alloc);
        defer glsl.deinit();
        try shadertoy.glslFromShaderFor(&glsl.writer, shader, .hlsl);
        try glsl.writer.writeByte(0);
        const src = glsl.written()[0 .. glsl.written().len - 1 :0];
        var spv: std.Io.Writer.Allocating = .init(alloc);
        defer spv.deinit();
        try shadertoy.spirvFromGlsl(&spv.writer, null, src);
        var words: std.ArrayListAligned(u8, .of(u32)) = .empty;
        defer words.deinit(alloc);
        try words.appendSlice(alloc, spv.written());
        const hlsl = try shadertoy.hlslFromSpv(alloc, words.items);
        defer alloc.free(hlsl);
        const code = try Device.compileStage(alloc, hlsl, "custom-shader", "main", "ps_5_0");
        alloc.free(code);
    }
}

test "the build compiled every program" {
    // src/build/DxbcStep.zig's list against `sources`: a program it misses
    // would compile at run time, silently slower.
    const dxbc = @import("murrtty_dxbc");
    if (!@hasDecl(dxbc, "built")) return error.SkipZigTest;
    inline for (comptime std.enums.values(Device.Program)) |p| {
        if (comptime @hasDecl(dxbc, @tagName(p))) {
            const code: [2][]const u8 = @field(dxbc, @tagName(p));
            try std.testing.expectEqualSlices(u8, "DXBC", code[0][0..4]);
            if (comptime sources.get(p).ps.len > 0) {
                try std.testing.expectEqualSlices(u8, "DXBC", code[1][0..4]);
            } else {
                try std.testing.expectEqual(@as(usize, 0), code[1].len);
            }
        } else {
            std.debug.print("the build didn't compile {t}\n", .{p});
            return error.TestUnexpectedResult;
        }
    }
}

test "every program compiles" {
    const alloc = std.testing.allocator;
    for (std.enums.values(Device.Program)) |p| {
        const src = sources.get(p);
        const vs = try Device.compileStage(alloc, src.text, @tagName(p), src.vs, "vs_5_0");
        alloc.free(vs);
        if (src.ps.len > 0) {
            const ps = try Device.compileStage(alloc, src.text, @tagName(p), src.ps, "ps_5_0");
            alloc.free(ps);
        }
    }
}
