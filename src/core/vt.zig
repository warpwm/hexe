const std = @import("std");
const log = @import("log.zig");

// Re-export ghostty-vt - this IS our terminal emulation
pub const ghostty = @import("ghostty-vt");
pub const Terminal = ghostty.Terminal;

const ReadonlyStream = @TypeOf((@as(*Terminal, undefined)).vtStream());

/// Thin wrapper around ghostty Terminal
pub const VT = struct {
    allocator: std.mem.Allocator = undefined,
    terminal: Terminal = undefined,
    stream: ReadonlyStream = undefined,
    render_state: ghostty.RenderState = .empty,
    width: u16 = 0,
    height: u16 = 0,

    /// Initialize the VT in-place.
    ///
    /// IMPORTANT: Ghostty terminal state must not be moved after initialization.
    /// This function initializes fields directly on `self` so the terminal lives
    /// at its final stable address.
    pub fn init(self: *VT, allocator: std.mem.Allocator, width: u16, height: u16) !void {
        self.* = .{ .allocator = allocator, .width = width, .height = height };

        self.terminal = try Terminal.init(allocator, .{ .cols = width, .rows = height });
        errdefer self.terminal.deinit(allocator);

        self.stream = self.terminal.vtStream();
        self.render_state = .empty;
    }

    pub fn deinit(self: *VT) void {
        self.render_state.deinit(self.allocator);
        self.stream.deinit();
        self.terminal.deinit(self.allocator);
        self.* = undefined;
    }

    /// Process input data through the terminal emulator.
    ///
    /// We must reuse the same stream across calls so the parser can maintain
    /// state for sequences that arrive split across PTY reads.
    pub fn feed(self: *VT, data: []const u8) !void {
        try self.stream.nextSlice(data);
    }

    /// Resize the virtual terminal
    pub fn resize(self: *VT, width: u16, height: u16) !void {
        if (width == self.width and height == self.height) return;
        try self.terminal.resize(self.allocator, width, height);
        self.width = width;
        self.height = height;
    }

    /// Get cursor position
    pub fn getCursor(self: *VT) struct { x: u16, y: u16 } {
        const cursor = self.terminal.screens.active.cursor;
        return .{ .x = cursor.x, .y = cursor.y };
    }

    /// Get cursor style (returns DECSCUSR value: 0=default, 1=block blink, 2=block, 3=underline blink, 4=underline, 5=bar blink, 6=bar)
    pub fn getCursorStyle(self: *VT) u8 {
        const screen = self.terminal.screens.active;
        const cursor_style = screen.cursor.cursor_style;
        const blink = self.terminal.modes.get(.cursor_blinking);
        // Map ghostty cursor style to DECSCUSR values
        return switch (cursor_style) {
            .block, .block_hollow => if (blink) 1 else 2,
            .underline => if (blink) 3 else 4,
            .bar => if (blink) 5 else 6,
        };
    }

    /// Check if cursor is visible
    pub fn isCursorVisible(self: *VT) bool {
        return self.terminal.modes.get(.cursor_visible);
    }

    /// Check if in alternate screen mode
    pub fn inAltScreen(self: *VT) bool {
        return self.terminal.screens.active_key == .alternate;
    }

    /// Get current working directory (from OSC 7)
    pub fn getPwd(self: *VT) ?[]const u8 {
        if (self.terminal.pwd.items.len == 0) return null;
        return self.terminal.pwd.items;
    }

    /// Update and return a stable snapshot of the currently visible viewport.
    ///
    /// This uses ghostty's `RenderState` which duplicates any managed cell data
    /// required for rendering. Reading cells via `PageList` directly can be
    /// fragile when pins/pages are shifting due to scrollback or resize.
    ///
    /// SAFETY: When scrollback is very large, this can fail or return invalid data.
    /// This function now keeps previous valid state as fallback when update fails.
    pub fn getRenderState(self: *VT) *const ghostty.RenderState {
        // Validation constants
        const MAX_REASONABLE_ROWS: usize = 10000;
        const MAX_REASONABLE_COLS: usize = 1000;

        // Check if current state is valid (for fallback purposes)
        const current_valid = self.render_state.rows > 0 and
            self.render_state.cols > 0 and
            self.render_state.rows <= MAX_REASONABLE_ROWS and
            self.render_state.cols <= MAX_REASONABLE_COLS;

        // Try to create new state
        var new_state: ghostty.RenderState = .empty;
        new_state.update(self.allocator, &self.terminal) catch |err| {
            // Update failed - return previous state if valid, else empty
            log.warn("RenderState update failed: {}, using fallback (valid={any})", .{ err, current_valid });
            if (current_valid) {
                return &self.render_state;
            }
            // Previous state also invalid - return empty
            return &self.render_state;
        };

        // Validate the new RenderState dimensions
        if (new_state.rows > MAX_REASONABLE_ROWS or new_state.cols > MAX_REASONABLE_COLS) {
            // New state has invalid dimensions - keep previous state if valid
            log.warn("RenderState has invalid dimensions ({d}x{d}), using fallback", .{ new_state.rows, new_state.cols });
            new_state.deinit(self.allocator);
            if (current_valid) {
                return &self.render_state;
            }
            // Previous state also invalid - reset to empty
            self.render_state.deinit(self.allocator);
            self.render_state = .empty;
            return &self.render_state;
        }

        // Success - swap states (free old, keep new)
        self.render_state.deinit(self.allocator);
        self.render_state = new_state;
        return &self.render_state;
    }
};
