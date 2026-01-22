const std = @import("std");

const Pane = @import("pane.zig").Pane;
const render = @import("render.zig");
const Renderer = render.Renderer;

pub const Pos = struct {
    x: u16 = 0,
    y: u16 = 0,
};

pub const Range = struct {
    a: Pos,
    b: Pos,
};

/// Pane-local selection state driven by mux mouse events.
///
/// Selection is locked to the pane where it started and is clamped to that
/// pane's content rectangle.
pub const MouseSelection = struct {
    tab: ?usize = null,
    pane_uuid: ?[32]u8 = null,

    active: bool = false,
    dragging: bool = false,

    anchor: Pos = .{},
    cursor: Pos = .{},

    // Keep the last selection highlighted after mouse release.
    has_range: bool = false,
    last_range: Range = .{ .a = .{}, .b = .{} },

    pub fn clear(self: *MouseSelection) void {
        self.* = .{};
    }

    pub fn begin(self: *MouseSelection, tab_idx: usize, pane_uuid: [32]u8, local_x: u16, local_y: u16) void {
        self.tab = tab_idx;
        self.pane_uuid = pane_uuid;
        self.active = true;
        self.dragging = false;
        self.anchor = .{ .x = local_x, .y = local_y };
        self.cursor = self.anchor;
        self.has_range = false;
    }

    pub fn update(self: *MouseSelection, local_x: u16, local_y: u16) void {
        if (!self.active) return;
        if (self.cursor.x != local_x or self.cursor.y != local_y) {
            self.dragging = true;
        }
        self.cursor = .{ .x = local_x, .y = local_y };
    }

    pub fn finish(self: *MouseSelection) void {
        if (!self.active) return;
        self.active = false;
        if (self.dragging) {
            self.has_range = true;
            self.last_range = .{ .a = self.anchor, .b = self.cursor };
        } else {
            self.has_range = false;
        }
    }

    pub fn rangeForPane(self: *const MouseSelection, tab_idx: usize, pane_uuid: [32]u8) ?Range {
        if (self.tab == null or self.pane_uuid == null) return null;
        if (self.tab.? != tab_idx) return null;
        if (!std.mem.eql(u8, &self.pane_uuid.?, &pane_uuid)) return null;

        if (self.active) return .{ .a = self.anchor, .b = self.cursor };
        if (self.has_range) return self.last_range;
        return null;
    }
};

fn clampToPane(x: u16, y: u16, w: u16, h: u16) Pos {
    const cx: u16 = if (w == 0) 0 else @min(x, w - 1);
    const cy: u16 = if (h == 0) 0 else @min(y, h - 1);
    return .{ .x = cx, .y = cy };
}

fn normalizeRange(range: Range) struct { start: Pos, end: Pos } {
    const a = range.a;
    const b = range.b;
    if (a.y < b.y or (a.y == b.y and a.x <= b.x)) {
        return .{ .start = a, .end = b };
    }
    return .{ .start = b, .end = a };
}

pub fn clampLocalToPane(local_x: u16, local_y: u16, pane_w: u16, pane_h: u16) Pos {
    return clampToPane(local_x, local_y, pane_w, pane_h);
}

pub fn applyOverlay(renderer: *Renderer, pane_x: u16, pane_y: u16, pane_w: u16, pane_h: u16, range: Range) void {
    if (pane_w == 0 or pane_h == 0) return;
    const a = clampToPane(range.a.x, range.a.y, pane_w, pane_h);
    const b = clampToPane(range.b.x, range.b.y, pane_w, pane_h);
    const norm = normalizeRange(.{ .a = a, .b = b });

    var y: u16 = norm.start.y;
    while (y <= norm.end.y) : (y += 1) {
        const start_x: u16 = if (y == norm.start.y) norm.start.x else 0;
        const end_x: u16 = if (y == norm.end.y) norm.end.x else (pane_w - 1);
        var x: u16 = start_x;
        while (x <= end_x) : (x += 1) {
            renderer.invertCell(pane_x + x, pane_y + y);
        }
    }
}

/// Extract selected text from the pane's current viewport RenderState.
///
/// Note: This is viewport-only (respects the current scrollback viewport).
pub fn extractText(allocator: std.mem.Allocator, pane: *Pane, pane_w: u16, pane_h: u16, range: Range) ![]u8 {
    if (pane_w == 0 or pane_h == 0) return allocator.dupe(u8, "");

    const a = clampToPane(range.a.x, range.a.y, pane_w, pane_h);
    const b = clampToPane(range.b.x, range.b.y, pane_w, pane_h);
    const norm = normalizeRange(.{ .a = a, .b = b });

    const state = pane.getRenderState() catch return allocator.dupe(u8, "");
    const row_slice = state.row_data.slice();
    if (row_slice.len == 0 or state.cols == 0 or state.rows == 0) return allocator.dupe(u8, "");

    const rows_max: u16 = @intCast(@min(@as(usize, pane_h), @min(@as(usize, state.rows), row_slice.len)));
    const cols_max: u16 = @intCast(@min(@as(usize, pane_w), @as(usize, state.cols)));
    if (rows_max == 0 or cols_max == 0) return allocator.dupe(u8, "");
    if (norm.start.y >= rows_max) return allocator.dupe(u8, "");

    const row_cells = row_slice.items(.cells);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var y: u16 = norm.start.y;
    while (y <= norm.end.y and y < rows_max) : (y += 1) {
        const start_x: u16 = if (y == norm.start.y) norm.start.x else 0;
        const end_x: u16 = if (y == norm.end.y) norm.end.x else (cols_max - 1);

        const cells_slice = row_cells[@intCast(y)].slice();
        const raw_cells = cells_slice.items(.raw);

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);

        var x: u16 = start_x;
        while (x <= end_x and x < cols_max and @as(usize, x) < raw_cells.len) : (x += 1) {
            const raw = raw_cells[@intCast(x)];
            if (raw.wide == .spacer_tail) continue;

            var cp: u21 = raw.codepoint();
            if (cp == 0 or cp < 32 or cp == 127) cp = ' ';

            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch {
                try line.append(allocator, ' ');
                continue;
            };
            try line.appendSlice(allocator, buf[0..len]);
        }

        const trimmed = std.mem.trimRight(u8, line.items, " ");
        try out.appendSlice(allocator, trimmed);
        if (y != norm.end.y and y + 1 < rows_max) {
            try out.append(allocator, '\n');
        }
    }

    return out.toOwnedSlice(allocator);
}
