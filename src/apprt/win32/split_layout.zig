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

/// How far from a pane's edge its grip band reaches, at most, in pixels.
/// Next to a divider, a pane leaves the mouse to the tab's container in its
/// margin (the padding and whatever the grid leaves over), but only this
/// close to the edge: the rest of a wide margin stays the pane's, so a
/// click there still focuses it and reaches the terminal.
pub const grip_reach = 64;

/// Which sides of a pane a point is in the grip band of.
pub const Sides = struct {
    left: bool = false,
    right: bool = false,
    top: bool = false,
    bottom: bool = false,

    pub fn any(self: Sides) bool {
        return self.left or self.right or self.top or self.bottom;
    }
};

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

        /// Every pane: in tree order, or the zoomed one first and then the
        /// hidden ones.
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
        /// node fills the area and the panes outside it get empty
        /// rectangles.
        pub fn compute(alloc: Allocator, tree: *const Tree, area: Rect, divider: i32) Allocator.Error!Self {
            var panes: std.ArrayList(Pane) = .empty;
            errdefer panes.deinit(alloc);
            var splits: std.ArrayList(Split) = .empty;
            errdefer splits.deinit(alloc);

            if (!tree.isEmpty()) {
                const mins = try alloc.alloc(Size, tree.nodes.len);
                defer alloc.free(mins);
                _ = minSize(tree, mins, .root, divider, .minimum);
                const ones = try alloc.alloc(Size, tree.nodes.len);
                defer alloc.free(ones);
                _ = minSize(tree, ones, .root, divider, .pixel);

                var ctx: Ctx = .{
                    .alloc = alloc,
                    .tree = tree,
                    .mins = mins,
                    .ones = ones,
                    .divider = divider,
                    .panes = &panes,
                    .splits = &splits,
                };
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
                } else {
                    try ctx.place(.root, area);
                }
            }

            const pane_slice = try panes.toOwnedSlice(alloc);
            errdefer alloc.free(pane_slice);
            return .{
                .panes = pane_slice,
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

        /// The split whose divider borders pane rectangle `pane` on one of
        /// `sides`, beside (x, y): for a point in that pane's grip band on
        /// those sides. Only a divider on a band's own side counts, however
        /// near another one runs; at a corner, where two sides' bands meet,
        /// the nearer divider wins.
        pub fn bandDivider(self: *const Self, pane: Rect, sides: Sides, x: i32, y: i32) ?Split {
            var best: ?Split = null;
            var best_distance: i32 = std.math.maxInt(i32);
            for (self.splits) |s| {
                // Panes touch their dividers, so a bordering divider's line
                // starts or ends exactly at the pane's edge.
                const r = s.divider;
                const across: ?i32 = switch (s.layout) {
                    .horizontal => if (y < r.top or y >= r.bottom)
                        null
                    else if (sides.right and r.left == pane.right)
                        r.left - x
                    else if (sides.left and r.right == pane.left)
                        x - r.right + 1
                    else
                        null,
                    .vertical => if (x < r.left or x >= r.right)
                        null
                    else if (sides.bottom and r.top == pane.bottom)
                        r.top - y
                    else if (sides.top and r.bottom == pane.top)
                        y - r.bottom + 1
                    else
                        null,
                };
                const distance = across orelse continue;
                if (distance < best_distance) {
                    best = s;
                    best_distance = distance;
                }
            }
            return best;
        }

        /// The smallest area `tree` fits in with every pane at its minimum.
        pub fn minimum(alloc: Allocator, tree: *const Tree, divider: i32) Allocator.Error!Size {
            if (tree.isEmpty()) return .{};
            const mins = try alloc.alloc(Size, tree.nodes.len);
            defer alloc.free(mins);
            return minSize(tree, mins, .root, divider, .minimum);
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

        /// The ratio that moves split `s`'s divider `amount` pixels from
        /// where it is drawn, as far as the sides' minimums allow: for
        /// resize_split. Not from the stored ratio, which a minimum can
        /// hold the divider away from (in a narrowed tab, say) by more than
        /// a step, so that no step would move it.
        pub fn stepRatio(self: *const Self, s: Split, amount: i32) f16 {
            const first = switch (s.layout) {
                .horizontal => s.divider.left - s.rect.left,
                .vertical => s.divider.top - s.rect.top,
            };
            return self.dragRatio(s, first + amount);
        }

        /// The split resize_split moves for pane `from`, as
        /// SplitTree.resize picks it: the nearest one above the pane that
        /// lays out `layout`.
        pub fn parentSplit(tree: *const Tree, from: Handle, layout: SplitLayout) ?Handle {
            var found: ?Handle = null;
            var at: Handle = .root;
            while (at != from) switch (tree.nodes[at.idx()]) {
                .leaf => return null,
                .split => |s| {
                    if (s.layout == layout) found = at;
                    at = if (isWithin(tree, from, s.left)) s.left else s.right;
                },
            };
            return found;
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
        pub fn isWithin(tree: *const Tree, h: Handle, ancestor: Handle) bool {
            if (h == ancestor) return true;
            return switch (tree.nodes[ancestor.idx()]) {
                .leaf => false,
                .split => |s| isWithin(tree, h, s.left) or isWithin(tree, h, s.right),
            };
        }

        /// Fill `mins` with each node's minimum size and return node `h`'s:
        /// with every pane at its minimum (`.minimum`), or at a pixel each
        /// way (`.pixel`), plus the dividers between them.
        fn minSize(tree: *const Tree, mins: []Size, h: Handle, divider: i32, kind: enum { minimum, pixel }) Size {
            const size: Size = switch (tree.nodes[h.idx()]) {
                .leaf => |v| leaf: {
                    if (kind == .pixel) break :leaf .{ .width = 1, .height = 1 };
                    const m = v.layoutMin();
                    break :leaf .{ .width = @max(1, m.width), .height = @max(1, m.height) };
                },
                .split => |s| split: {
                    const a = minSize(tree, mins, s.left, divider, kind);
                    const b = minSize(tree, mins, s.right, divider, kind);
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
            /// Each node's minimum, and its size with a pixel per pane.
            mins: []const Size,
            ones: []const Size,
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
                        const first = firstLength(avail, s.ratio, .{ min_first, min_second }, .{
                            minAcross(self.ones[s.left.idx()], s.layout),
                            minAcross(self.ones[s.right.idx()], s.layout),
                        });
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
        /// within both sides' minimums (`mins`). When both don't fit, a
        /// share in proportion to them, keeping a pixel for every pane and
        /// room for the dividers between them on each side (`ones`) where
        /// that fits, else a pixel for each side.
        fn firstLength(avail: i32, ratio: f16, mins: [2]i32, ones: [2]i32) i32 {
            if (avail <= 1) return avail;
            const want: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(avail)) * @as(f32, ratio)));
            if (mins[0] <= avail - mins[1]) return std.math.clamp(want, mins[0], avail - mins[1]);
            const total: f32 = @floatFromInt(mins[0] + mins[1]);
            const share: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(avail)) * @as(f32, @floatFromInt(mins[0])) / total));
            if (ones[0] <= avail - ones[1]) return std.math.clamp(share, ones[0], avail - ones[1]);
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

/// `len` cut down to `pad` and whole `cell`s, at least one
/// (window-step-resize).
pub fn snapToCells(len: i32, pad: u32, cell: u32) i32 {
    if (cell == 0) return len;
    const p: i32 = @intCast(pad);
    const cl: i32 = @intCast(cell);
    const cells = @max(1, @divFloor(len - p, cl));
    return p + cells * cl;
}

test "split_layout: snapToCells keeps whole cells beside the padding" {
    try std.testing.expectEqual(@as(i32, 4 + 10 * 9), snapToCells(4 + 10 * 9, 4, 9));
    try std.testing.expectEqual(@as(i32, 4 + 10 * 9), snapToCells(4 + 10 * 9 + 8, 4, 9));
    try std.testing.expectEqual(@as(i32, 4 + 11 * 9), snapToCells(4 + 11 * 9, 4, 9));
    try std.testing.expectEqual(@as(i32, 4 + 9), snapToCells(3, 4, 9));
    try std.testing.expectEqual(@as(i32, 50), snapToCells(50, 4, 0));
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

test "split_layout: a squeezed side keeps a pixel for each of its panes" {
    // A | (B | C) with A's minimum far larger than the area: the right side
    // needs 1 + 1 + 1 pixels for B, its divider and C, not just one.
    const alloc = testing.allocator;
    var views = [_]TestView{ .{ .label = "A", .min = .{ .width = 100 } }, .{ .label = "B" }, .{ .label = "C" } };
    var tree = try build(alloc, &views, &.{
        .{ .at = "A", .dir = .right },
        .{ .at = "B", .dir = .right },
    });
    defer tree.deinit();
    const area: Rect = .{ .right = 51, .bottom = 10 };
    var layout = try L.compute(alloc, &tree, area, 1);
    defer layout.deinit(alloc);
    for (layout.panes) |p| try testing.expect(!p.rect.isEmpty());
    try testing.expectEqual(@as(i32, 47), paneRect(&layout, "A").width());
    try expectTiles(&layout, area);
}

test "split_layout: no leaks when an allocation fails" {
    const alloc = testing.allocator;
    var views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" } };
    var tree = try build(alloc, &views, &.{
        .{ .at = "A", .dir = .right },
        .{ .at = "B", .dir = .down },
    });
    defer tree.deinit();
    try testing.checkAllAllocationFailures(alloc, struct {
        fn run(a: Allocator, t: *const L.Tree) !void {
            var layout = try L.compute(a, t, .{ .right = 800, .bottom = 600 }, 1);
            layout.deinit(a);
        }
    }.run, .{&tree});
}

test "split_layout: a zoomed split keeps its divider" {
    const alloc = testing.allocator;
    var views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" } };
    var tree = try build(alloc, &views, &.{
        .{ .at = "A", .dir = .right },
        .{ .at = "B", .dir = .down },
    });
    defer tree.deinit();
    // The split holding B and C.
    const split: L.Handle = switch (tree.nodes[0]) {
        .split => |s| s.right,
        .leaf => unreachable,
    };
    tree.zoom(split);
    const area: Rect = .{ .right = 800, .bottom = 601 };
    var layout = try L.compute(alloc, &tree, area, 1);
    defer layout.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), layout.splits.len);
    try testing.expect(paneRect(&layout, "A").isEmpty());
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

test "split_layout: a grip band's divider is on its own side, and a tree's minimum" {
    const alloc = testing.allocator;
    var views = [_]TestView{
        .{ .label = "A", .min = .{ .width = 80, .height = 40 } },
        .{ .label = "B", .min = .{ .width = 50, .height = 30 } },
        .{ .label = "C", .min = .{ .width = 60, .height = 20 } },
    };
    var tree = try build(alloc, &views, &.{
        .{ .at = "A", .dir = .right },
        .{ .at = "B", .dir = .down },
    });
    defer tree.deinit();
    var layout = try L.compute(alloc, &tree, .{ .right = 1001, .bottom = 601 }, 1);
    defer layout.deinit(alloc);

    // Column 500 is the side-by-side divider; row 300 of the right half is
    // the stacked one.
    const a = paneRect(&layout, "A");
    const b = paneRect(&layout, "B");
    const cc = paneRect(&layout, "C");
    try testing.expectEqual(L.SplitLayout.horizontal, layout.bandDivider(a, .{ .right = true }, 497, 100).?.layout);
    try testing.expectEqual(L.SplitLayout.vertical, layout.bandDivider(cc, .{ .top = true }, 800, 303).?.layout);
    // At a corner, in two bands: the stacked line is 1 away, the
    // side-by-side one 3.
    try testing.expectEqual(L.SplitLayout.vertical, layout.bandDivider(cc, .{ .left = true, .top = true }, 503, 301).?.layout);
    // In B's left band only, near its bottom: the side-by-side divider,
    // though the stacked one is nearer.
    try testing.expectEqual(L.SplitLayout.horizontal, layout.bandDivider(b, .{ .left = true }, 503, 298).?.layout);
    // In no band, or a band on a side with no divider (the tab's edge).
    try testing.expect(layout.bandDivider(b, .{}, 503, 298) == null);
    try testing.expect(layout.bandDivider(a, .{ .left = true }, 2, 100) == null);
    try testing.expect(layout.bandDivider(a, .{ .bottom = true }, 300, 599) == null);

    // A | (B / C): 80 + 1 + max(50, 60) wide, max(40, 30 + 1 + 20) high.
    const min = try L.minimum(alloc, &tree, 1);
    try testing.expectEqual(@as(i32, 141), min.width);
    try testing.expectEqual(@as(i32, 51), min.height);
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

test "split_layout: a resize step moves the divider from where it is drawn" {
    const alloc = testing.allocator;
    var views = [_]TestView{
        .{ .label = "A", .min = .{ .width = 100 } },
        .{ .label = "B", .min = .{ .width = 100 } },
        .{ .label = "C" },
    };
    // A | (B / C), the root at 0.15.
    var tree = try build(alloc, &views, &.{
        .{ .at = "A", .dir = .right, .ratio = 0.15 },
        .{ .at = "B", .dir = .down },
    });
    defer tree.deinit();

    // The split each way, as SplitTree.resize picks it.
    const from_c = tree.locate(&views[2]).?;
    try testing.expectEqual(L.Handle.root, L.parentSplit(&tree, from_c, .horizontal).?);
    const stacked = L.parentSplit(&tree, from_c, .vertical).?;
    try testing.expect(stacked != .root);
    try testing.expectEqual(L.SplitLayout.vertical, tree.nodes[stacked.idx()].split.layout);
    try testing.expect(L.parentSplit(&tree, tree.locate(&views[0]).?, .vertical) == null);

    // 481 px wide: the ratio wants A at 72 px, its minimum holds it at 100.
    const area: Rect = .{ .right = 481, .bottom = 300 };
    var held = try L.compute(alloc, &tree, area, 1);
    defer held.deinit(alloc);
    try testing.expectEqual(@as(i32, 100), paneRect(&held, "A").width());

    // A 10 px step right moves it to 110 (from the ratio, it wouldn't move).
    tree.resizeInPlace(.root, held.stepRatio(held.findSplit(.root).?, 10));
    var stepped = try L.compute(alloc, &tree, area, 1);
    defer stepped.deinit(alloc);
    try testing.expectEqual(@as(i32, 110), paneRect(&stepped, "A").width());

    // A step left stops at the minimum.
    tree.resizeInPlace(.root, stepped.stepRatio(stepped.findSplit(.root).?, -50));
    var back = try L.compute(alloc, &tree, area, 1);
    defer back.deinit(alloc);
    try testing.expectEqual(@as(i32, 100), paneRect(&back, "A").width());
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
