//! Where a tab's panes and dividers go: a pure function of the split tree,
//! the tab's area, the divider thickness and each pane's minimum size, so
//! it is unit-tested with no windows. The rectangles tile the area exactly:
//! every pixel belongs to one pane or one divider.
//!
//! "Horizontal" splits put panes side by side, with a vertical divider
//! line; "vertical" splits stack them (the split tree's naming).
const std = @import("std");
const Allocator = std.mem.Allocator;
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;

pub const Rect = struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,

    pub fn width(self: Rect) i32 {
        return self.right - self.left;
    }

    pub fn height(self: Rect) i32 {
        return self.bottom - self.top;
    }

    pub fn isEmpty(self: Rect) bool {
        return self.right <= self.left or self.bottom <= self.top;
    }

    pub fn contains(self: Rect, x: i32, y: i32) bool {
        return x >= self.left and x < self.right and y >= self.top and y < self.bottom;
    }
};

pub const Size = struct {
    width: i32 = 1,
    height: i32 = 1,
};

/// A divider is 1 DIP (device-independent pixel) thick, at least 1 pixel.
pub fn dividerWidth(dpi: u32) i32 {
    return @max(1, @as(i32, @intCast((dpi + 48) / 96)));
}

/// The layout of a split tree of `View`s. View must have
/// `fn layoutMin(*const View) Size`: the smallest a pane may be, in pixels.
pub fn Layout(comptime View: type) type {
    return struct {
        const Self = @This();
        pub const Tree = SplitTree(View);
        pub const Handle = Tree.Node.Handle;
        pub const SplitLayout = Tree.Split.Layout;

        pub const Pane = struct {
            handle: Handle,
            view: *View,
            /// Empty for a pane hidden by another one's zoom.
            rect: Rect,
        };

        pub const Split = struct {
            handle: Handle,
            layout: SplitLayout,
            /// The area of both sides and the divider.
            rect: Rect,
            divider: Rect,
            /// The smallest each side may be across the divider.
            min_first: i32,
            min_second: i32,
        };

        /// Every pane in tree order.
        panes: []Pane,
        /// The splits with a divider on screen (none while zoomed).
        splits: []Split,
        divider: i32,

        pub fn deinit(self: *Self, alloc: Allocator) void {
            alloc.free(self.panes);
            alloc.free(self.splits);
            self.* = undefined;
        }

        /// Lay out `tree` in `area` with dividers `divider` pixels thick.
        /// Each pane gets at least its minimum where the area allows, and
        /// at least a pixel each way where the area allows that. A zoomed
        /// pane fills the area and the others get empty rectangles.
        pub fn compute(alloc: Allocator, tree: *const Tree, area: Rect, divider: i32) Allocator.Error!Self {
            var panes: std.ArrayList(Pane) = .empty;
            errdefer panes.deinit(alloc);
            var splits: std.ArrayList(Split) = .empty;
            errdefer splits.deinit(alloc);

            if (!tree.isEmpty()) {
                const mins = try alloc.alloc(Size, tree.nodes.len);
                defer alloc.free(mins);
                _ = minSize(tree, mins, .root, divider);

                var ctx: Ctx = .{ .alloc = alloc, .tree = tree, .mins = mins, .divider = divider, .panes = &panes, .splits = &splits };
                if (tree.zoomed) |zoomed| {
                    try ctx.place(zoomed, area);
                    // The rest are hidden.
                    var it = tree.iterator();
                    while (it.next()) |entry| {
                        if (!isWithin(tree, entry.handle, zoomed)) try panes.append(alloc, .{
                            .handle = entry.handle,
                            .view = entry.view,
                            .rect = .{},
                        });
                    }
                    splits.clearRetainingCapacity();
                } else {
                    try ctx.place(.root, area);
                }
            }

            return .{
                .panes = try panes.toOwnedSlice(alloc),
                .splits = try splits.toOwnedSlice(alloc),
                .divider = divider,
            };
        }

        /// The pane covering (x, y), if any.
        pub fn paneAt(self: *const Self, x: i32, y: i32) ?Pane {
            for (self.panes) |p| if (p.rect.contains(x, y)) return p;
            return null;
        }

        /// The split whose divider is at (x, y), counting `grip` pixels on
        /// each side of the line as part of it: the band a drag can start
        /// in, which callers keep within the panes' padding so it never
        /// takes a click meant for the first or last column.
        pub fn dividerAt(self: *const Self, x: i32, y: i32, grip: i32) ?Split {
            // The line itself wins over a neighbor's band.
            for (self.splits) |s| if (s.divider.contains(x, y)) return s;
            for (self.splits) |s| if (band(s, grip).contains(x, y)) return s;
            return null;
        }

        pub fn findSplit(self: *const Self, handle: Handle) ?Split {
            for (self.splits) |s| if (s.handle == handle) return s;
            return null;
        }

        /// The ratio that puts split `s`'s divider `first` pixels from the
        /// split's start (its left or top edge), as near as the sides'
        /// minimums allow: for dragging a divider.
        pub fn dragRatio(self: *const Self, s: Split, first: i32) f16 {
            const avail = length(s.rect, s.layout) - self.divider;
            if (avail <= 0) return 0.5;
            const lo = s.min_first;
            const hi = avail - s.min_second;
            const clamped = if (lo <= hi) std.math.clamp(first, lo, hi) else std.math.clamp(first, 0, avail);
            const ratio = @as(f32, @floatFromInt(clamped)) / @as(f32, @floatFromInt(avail));
            return @floatCast(std.math.clamp(ratio, 0, 1));
        }

        /// The ratio delta for SplitTree.resize that moves a divider by
        /// `amount` pixels in a tab whose area is `area`: resize takes the
        /// delta as a fraction of the whole tree's width (side by side) or
        /// height (stacked). Clamped to [-1, 1], since resize asserts on
        /// larger deltas.
        pub fn resizeDelta(area: Rect, layout: SplitLayout, amount: i32) f16 {
            const len = length(area, layout);
            if (len <= 0) return 0;
            const delta = @as(f32, @floatFromInt(amount)) / @as(f32, @floatFromInt(len));
            return @floatCast(std.math.clamp(delta, -1, 1));
        }

        /// The pane to focus after closing pane `closing`: the one before
        /// it, else the one after it (in tree order), or null if it was the
        /// only one.
        pub fn focusAfterClose(alloc: Allocator, tree: *const Tree, closing: Handle) Allocator.Error!?*View {
            const next = try tree.goto(alloc, closing, .previous) orelse
                try tree.goto(alloc, closing, .next) orelse
                return null;
            return switch (tree.nodes[next.idx()]) {
                .leaf => |v| v,
                .split => null,
            };
        }

        fn band(s: Split, grip: i32) Rect {
            var r = s.divider;
            switch (s.layout) {
                .horizontal => {
                    r.left -= grip;
                    r.right += grip;
                },
                .vertical => {
                    r.top -= grip;
                    r.bottom += grip;
                },
            }
            return r;
        }

        fn length(r: Rect, layout: SplitLayout) i32 {
            return switch (layout) {
                .horizontal => r.width(),
                .vertical => r.height(),
            };
        }

        /// Whether node `h` is `ancestor` or below it.
        fn isWithin(tree: *const Tree, h: Handle, ancestor: Handle) bool {
            if (h == ancestor) return true;
            return switch (tree.nodes[ancestor.idx()]) {
                .leaf => false,
                .split => |s| isWithin(tree, h, s.left) or isWithin(tree, h, s.right),
            };
        }

        /// Fill `mins` with each node's minimum size and return node `h`'s.
        fn minSize(tree: *const Tree, mins: []Size, h: Handle, divider: i32) Size {
            const size: Size = switch (tree.nodes[h.idx()]) {
                .leaf => |v| leaf: {
                    const m = v.layoutMin();
                    break :leaf .{ .width = @max(1, m.width), .height = @max(1, m.height) };
                },
                .split => |s| split: {
                    const a = minSize(tree, mins, s.left, divider);
                    const b = minSize(tree, mins, s.right, divider);
                    break :split switch (s.layout) {
                        .horizontal => .{ .width = a.width + divider + b.width, .height = @max(a.height, b.height) },
                        .vertical => .{ .width = @max(a.width, b.width), .height = a.height + divider + b.height },
                    };
                },
            };
            mins[h.idx()] = size;
            return size;
        }

        const Ctx = struct {
            alloc: Allocator,
            tree: *const Tree,
            mins: []const Size,
            divider: i32,
            panes: *std.ArrayList(Pane),
            splits: *std.ArrayList(Split),

            fn place(self: *Ctx, h: Handle, r: Rect) Allocator.Error!void {
                switch (self.tree.nodes[h.idx()]) {
                    .leaf => |v| try self.panes.append(self.alloc, .{ .handle = h, .view = v, .rect = r }),
                    .split => |s| {
                        const min_first = minAcross(self.mins[s.left.idx()], s.layout);
                        const min_second = minAcross(self.mins[s.right.idx()], s.layout);
                        const len = length(r, s.layout);
                        const d = @min(self.divider, @max(len, 0));
                        const avail = @max(len - d, 0);
                        const first = firstLength(avail, s.ratio, min_first, min_second);
                        var a = r;
                        var line = r;
                        var b = r;
                        switch (s.layout) {
                            .horizontal => {
                                a.right = r.left + first;
                                line.left = a.right;
                                line.right = line.left + d;
                                b.left = line.right;
                            },
                            .vertical => {
                                a.bottom = r.top + first;
                                line.top = a.bottom;
                                line.bottom = line.top + d;
                                b.top = line.bottom;
                            },
                        }
                        try self.splits.append(self.alloc, .{
                            .handle = h,
                            .layout = s.layout,
                            .rect = r,
                            .divider = line,
                            .min_first = min_first,
                            .min_second = min_second,
                        });
                        try self.place(s.left, a);
                        try self.place(s.right, b);
                    },
                }
            }
        };

        fn minAcross(m: Size, layout: SplitLayout) i32 {
            return switch (layout) {
                .horizontal => m.width,
                .vertical => m.height,
            };
        }

        /// The first side's length out of `avail` pixels: the ratio's,
        /// within both sides' minimums; or, when both don't fit, a share in
        /// proportion to them with at least a pixel for each.
        fn firstLength(avail: i32, ratio: f16, min_first: i32, min_second: i32) i32 {
            if (avail <= 1) return avail;
            const want: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(avail)) * @as(f32, ratio)));
            const lo = min_first;
            const hi = avail - min_second;
            if (lo <= hi) return std.math.clamp(want, lo, hi);
            const total: f32 = @floatFromInt(min_first + min_second);
            const share: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(avail)) * @as(f32, @floatFromInt(min_first)) / total));
            return std.math.clamp(share, 1, avail - 1);
        }
    };
}

//---------------------------------------------------------------
// Tests

const testing = std.testing;

/// A pane for the tests: a label and a minimum size.
const TestView = struct {
    label: []const u8,
    min: Size = .{},

    pub fn ref(self: *TestView) *TestView {
        return self;
    }

    pub fn unref(self: *TestView) void {
        _ = self;
    }

    pub fn eql(a: *const TestView, b: *const TestView) bool {
        return a == b;
    }

    pub fn layoutMin(self: *const TestView) Size {
        return self.min;
    }
};

const L = Layout(TestView);

/// A tree of `views` built by splitting the previous tree's `at` leaf
/// (by label) in `dir` at `ratio`, one step per view after the first.
const Step = struct { at: []const u8, dir: L.Tree.Split.Direction, ratio: f16 = 0.5 };

fn build(alloc: Allocator, views: []TestView, steps: []const Step) !L.Tree {
    var tree = try L.Tree.init(alloc, &views[0]);
    errdefer tree.deinit();
    for (steps, views[1..]) |step, *v| {
        var leaf = try L.Tree.init(alloc, v);
        defer leaf.deinit();
        const at = for (views) |*candidate| {
            if (std.mem.eql(u8, candidate.label, step.at)) break tree.locate(candidate).?;
        } else unreachable;
        const next = try tree.split(alloc, at, step.dir, step.ratio, &leaf);
        tree.deinit();
        tree = next;
    }
    return tree;
}

fn paneRect(layout: *const L, label: []const u8) Rect {
    for (layout.panes) |p| if (std.mem.eql(u8, p.view.label, label)) return p.rect;
    unreachable;
}

/// Every pixel of `area` is in exactly one pane or divider.
fn expectTiles(layout: *const L, area: Rect) !void {
    var total: i64 = 0;
    var rects: std.ArrayList(Rect) = .empty;
    defer rects.deinit(testing.allocator);
    for (layout.panes) |p| if (!p.rect.isEmpty()) try rects.append(testing.allocator, p.rect);
    for (layout.splits) |s| if (!s.divider.isEmpty()) try rects.append(testing.allocator, s.divider);
    for (rects.items, 0..) |a, i| {
        try testing.expect(a.left >= area.left and a.top >= area.top and a.right <= area.right and a.bottom <= area.bottom);
        total += @as(i64, a.width()) * a.height();
        for (rects.items[i + 1 ..]) |b| {
            const overlap = a.left < b.right and b.left < a.right and a.top < b.bottom and b.top < a.bottom;
            try testing.expect(!overlap);
        }
    }
    try testing.expectEqual(@as(i64, area.width()) * area.height(), total);
}

test "split_layout: divider width follows the DPI" {
    try testing.expectEqual(@as(i32, 1), dividerWidth(96));
    try testing.expectEqual(@as(i32, 1), dividerWidth(120));
    try testing.expectEqual(@as(i32, 2), dividerWidth(144));
    try testing.expectEqual(@as(i32, 2), dividerWidth(192));
    try testing.expectEqual(@as(i32, 3), dividerWidth(288));
}

test "split_layout: one pane fills the area" {
    const alloc = testing.allocator;
    var views = [_]TestView{.{ .label = "A" }};
    var tree = try build(alloc, &views, &.{});
    defer tree.deinit();
    const area: Rect = .{ .left = 3, .top = 7, .right = 803, .bottom = 607 };
    var layout = try L.compute(alloc, &tree, area, 1);
    defer layout.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), layout.panes.len);
    try testing.expectEqual(@as(usize, 0), layout.splits.len);
    try testing.expectEqual(area, layout.panes[0].rect);
}

test "split_layout: panes and dividers tile the area exactly" {
    const alloc = testing.allocator;
    var views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" }, .{ .label = "D" } };
    var tree = try build(alloc, &views, &.{
        .{ .at = "A", .dir = .right },
        .{ .at = "B", .dir = .down, .ratio = 0.3 },
        .{ .at = "A", .dir = .down, .ratio = 0.7 },
    });
    defer tree.deinit();
    // Odd sizes and dividers, so the halves round.
    for ([_]Rect{
        .{ .right = 1001, .bottom = 601 },
        .{ .left = 5, .top = 9, .right = 806, .bottom = 444 },
    }) |area| for ([_]i32{ 1, 2, 3 }) |d| {
        var layout = try L.compute(alloc, &tree, area, d);
        defer layout.deinit(alloc);
        try testing.expectEqual(@as(usize, 4), layout.panes.len);
        try testing.expectEqual(@as(usize, 3), layout.splits.len);
        try expectTiles(&layout, area);
        for (layout.splits) |s| try testing.expectEqual(d, switch (s.layout) {
            .horizontal => s.divider.width(),
            .vertical => s.divider.height(),
        });
    };

    // A side by side split at 0.5 halves what the divider leaves.
    var layout = try L.compute(alloc, &tree, .{ .right = 1001, .bottom = 600 }, 1);
    defer layout.deinit(alloc);
    try testing.expectEqual(@as(i32, 500), paneRect(&layout, "A").width());
    try testing.expectEqual(@as(i32, 500), paneRect(&layout, "B").width());
    try testing.expectEqual(@as(i32, 501), paneRect(&layout, "B").left);
}

test "split_layout: minimums win over the ratio" {
    const alloc = testing.allocator;
    var views = [_]TestView{ .{ .label = "A", .min = .{ .width = 80, .height = 40 } }, .{ .label = "B", .min = .{ .width = 120, .height = 40 } } };
    var tree = try build(alloc, &views, &.{.{ .at = "A", .dir = .right, .ratio = 0.05 }});
    defer tree.deinit();
    const area: Rect = .{ .right = 1001, .bottom = 300 };
    {
        var layout = try L.compute(alloc, &tree, area, 1);
        defer layout.deinit(alloc);
        try testing.expectEqual(@as(i32, 80), paneRect(&layout, "A").width());
        try expectTiles(&layout, area);
    }

    // At the other end, B keeps its minimum.
    tree.resizeInPlace(.root, 0.99);
    {
        var layout = try L.compute(alloc, &tree, area, 1);
        defer layout.deinit(alloc);
        try testing.expectEqual(@as(i32, 120), paneRect(&layout, "B").width());
        try expectTiles(&layout, area);
    }

    // Too small for both: shared in proportion, a pixel at least.
    {
        const small: Rect = .{ .right = 101, .bottom = 30 };
        var layout = try L.compute(alloc, &tree, small, 1);
        defer layout.deinit(alloc);
        try testing.expectEqual(@as(i32, 40), paneRect(&layout, "A").width());
        try testing.expectEqual(@as(i32, 60), paneRect(&layout, "B").width());
        try expectTiles(&layout, small);
    }
    {
        const tiny: Rect = .{ .right = 3, .bottom = 30 };
        var layout = try L.compute(alloc, &tree, tiny, 1);
        defer layout.deinit(alloc);
        try testing.expectEqual(@as(i32, 1), paneRect(&layout, "A").width());
        try testing.expectEqual(@as(i32, 1), paneRect(&layout, "B").width());
        try expectTiles(&layout, tiny);
    }

    // Nested: the minimum of a subtree is its panes' and divider's.
    var more = [_]TestView{
        .{ .label = "A", .min = .{ .width = 50 } },
        .{ .label = "B", .min = .{ .width = 50 } },
        .{ .label = "C", .min = .{ .width = 50 } },
    };
    var nested = try build(alloc, &more, &.{
        .{ .at = "A", .dir = .right, .ratio = 0.9 },
        .{ .at = "A", .dir = .right, .ratio = 0.5 },
    });
    defer nested.deinit();
    // (A | C) | B with the root at 0.01: the left side keeps 50 + 1 + 50.
    nested.resizeInPlace(.root, 0.01);
    var layout = try L.compute(alloc, &nested, area, 1);
    defer layout.deinit(alloc);
    try testing.expectEqual(@as(i32, 50), paneRect(&layout, "A").width());
    try testing.expectEqual(@as(i32, 50), paneRect(&layout, "C").width());
    try testing.expectEqual(@as(i32, 50 + 1 + 50 + 1), paneRect(&layout, "B").left);
    try expectTiles(&layout, area);
}

test "split_layout: a zoomed pane fills the area" {
    const alloc = testing.allocator;
    var views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" } };
    var tree = try build(alloc, &views, &.{
        .{ .at = "A", .dir = .right },
        .{ .at = "B", .dir = .down },
    });
    defer tree.deinit();
    tree.zoom(tree.locate(&views[1]));
    const area: Rect = .{ .right = 800, .bottom = 600 };
    var layout = try L.compute(alloc, &tree, area, 1);
    defer layout.deinit(alloc);
    try testing.expectEqual(@as(usize, 3), layout.panes.len);
    try testing.expectEqual(@as(usize, 0), layout.splits.len);
    try testing.expectEqual(area, paneRect(&layout, "B"));
    try testing.expect(paneRect(&layout, "A").isEmpty());
    try testing.expect(paneRect(&layout, "C").isEmpty());
}

test "split_layout: hit-testing panes, dividers and the grip band" {
    const alloc = testing.allocator;
    var views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" } };
    var tree = try build(alloc, &views, &.{
        .{ .at = "A", .dir = .right },
        .{ .at = "B", .dir = .down },
    });
    defer tree.deinit();
    var layout = try L.compute(alloc, &tree, .{ .right = 1001, .bottom = 601 }, 1);
    defer layout.deinit(alloc);

    // The side-by-side divider is column 500, the stacked one row 300 of
    // the right half.
    try testing.expectEqualStrings("A", layout.paneAt(499, 10).?.view.label);
    try testing.expectEqualStrings("B", layout.paneAt(501, 299).?.view.label);
    try testing.expectEqualStrings("C", layout.paneAt(501, 301).?.view.label);
    try testing.expect(layout.paneAt(500, 10) == null);

    const root = layout.dividerAt(500, 10, 0).?;
    try testing.expectEqual(L.SplitLayout.horizontal, root.layout);
    try testing.expect(layout.dividerAt(498, 10, 2) != null);
    try testing.expect(layout.dividerAt(497, 10, 2) == null);
    try testing.expect(layout.dividerAt(498, 10, 0) == null);
    const stacked = layout.dividerAt(700, 301, 2).?;
    try testing.expectEqual(L.SplitLayout.vertical, stacked.layout);
    // On the stacked line next to the other divider's band, the line wins.
    try testing.expectEqual(L.SplitLayout.vertical, layout.dividerAt(502, 300, 2).?.layout);
}

test "split_layout: dragging moves the divider by the dragged distance" {
    const alloc = testing.allocator;
    var views = [_]TestView{ .{ .label = "A", .min = .{ .width = 100 } }, .{ .label = "B", .min = .{ .width = 100 } } };
    var tree = try build(alloc, &views, &.{.{ .at = "A", .dir = .right }});
    defer tree.deinit();
    const area: Rect = .{ .right = 2561, .bottom = 600 };

    var start = try L.compute(alloc, &tree, area, 1);
    const split = start.findSplit(.root).?;
    const at = split.divider.left;
    start.deinit(alloc);

    for ([_]i32{ 1, -1, 37, -250, 999 }) |delta| {
        var layout = try L.compute(alloc, &tree, area, 1);
        const s = layout.findSplit(.root).?;
        const ratio = layout.dragRatio(s, at + delta - s.rect.left);
        layout.deinit(alloc);
        var moved = tree;
        moved.resizeInPlace(.root, ratio);
        var after = try L.compute(alloc, &moved, area, 1);
        defer after.deinit(alloc);
        // f16 has 11 bits of fraction: within a pixel at this size.
        const got = after.findSplit(.root).?.divider.left;
        try testing.expect(@abs(got - (at + delta)) <= 1);
    }
    tree.resizeInPlace(.root, 0.5);

    // Not past a side's minimum.
    var layout = try L.compute(alloc, &tree, area, 1);
    defer layout.deinit(alloc);
    const s = layout.findSplit(.root).?;
    try testing.expectEqual(@as(f32, 100), @round(@as(f32, layout.dragRatio(s, 3)) * 2560));
    try testing.expectEqual(@as(f32, 2460), @round(@as(f32, layout.dragRatio(s, 5000)) * 2560));
}

test "split_layout: resize deltas are a fraction of the area, at most 1" {
    try testing.expectEqual(@as(f16, 0.1), L.resizeDelta(.{ .right = 1000, .bottom = 500 }, .horizontal, 100));
    try testing.expectEqual(@as(f16, -0.2), L.resizeDelta(.{ .right = 1000, .bottom = 500 }, .vertical, -100));
    try testing.expectEqual(@as(f16, 1), L.resizeDelta(.{ .right = 1000, .bottom = 500 }, .horizontal, 5000));
    try testing.expectEqual(@as(f16, -1), L.resizeDelta(.{ .right = 1000, .bottom = 500 }, .horizontal, -5000));
    try testing.expectEqual(@as(f16, 0), L.resizeDelta(.{}, .horizontal, 10));

    // Applied with SplitTree.resize, the divider moves by that much.
    const alloc = testing.allocator;
    var views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" } };
    var tree = try build(alloc, &views, &.{
        .{ .at = "A", .dir = .right },
        .{ .at = "B", .dir = .down },
    });
    defer tree.deinit();
    const area: Rect = .{ .right = 1001, .bottom = 601 };
    var before = try L.compute(alloc, &tree, area, 1);
    defer before.deinit(alloc);
    var resized = try tree.resize(alloc, tree.locate(&views[2]).?, .horizontal, L.resizeDelta(area, .horizontal, 100));
    defer resized.deinit();
    var after = try L.compute(alloc, &resized, area, 1);
    defer after.deinit(alloc);
    const moved = after.findSplit(.root).?.divider.left - before.findSplit(.root).?.divider.left;
    try testing.expect(@abs(moved - 100) <= 1);
}

test "split_layout: closing a pane focuses the one before it, else after it" {
    const alloc = testing.allocator;
    var views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" } };
    var tree = try build(alloc, &views, &.{
        .{ .at = "A", .dir = .right },
        .{ .at = "B", .dir = .down },
    });
    defer tree.deinit();
    try testing.expectEqualStrings("B", (try L.focusAfterClose(alloc, &tree, tree.locate(&views[2]).?)).?.label);
    try testing.expectEqualStrings("A", (try L.focusAfterClose(alloc, &tree, tree.locate(&views[1]).?)).?.label);
    try testing.expectEqualStrings("B", (try L.focusAfterClose(alloc, &tree, tree.locate(&views[0]).?)).?.label);

    var single = [_]TestView{.{ .label = "A" }};
    var one = try build(alloc, &single, &.{});
    defer one.deinit();
    try testing.expect(try L.focusAfterClose(alloc, &one, .root) == null);
}
