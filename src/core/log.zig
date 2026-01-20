const std = @import("std");
const posix = std.posix;

/// Log levels
pub const Level = enum {
    trace,
    debug,
    info,
    warn,
    err,

    pub fn prefix(self: Level) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO ",
            .warn => "WARN ",
            .err => "ERROR",
        };
    }

};

/// Component tags
pub const Component = enum {
    mux,
    ses,
    pod,

    pub fn prefix(self: Component) []const u8 {
        return switch (self) {
            .mux => "mux",
            .ses => "ses",
            .pod => "pod",
        };
    }
};

/// Global log file handle (-1 = disabled)
var g_log_fd: posix.fd_t = -1;

/// Global component tag
var g_component: Component = .mux;

/// Initialize logging to a file
pub fn init(path: []const u8, component: Component) void {
    g_component = component;
    if (path.len == 0) return;

    g_log_fd = posix.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644) catch |e| {
        std.debug.print("Failed to open log file {s}: {}\n", .{ path, e });
        return;
    };
}

/// Initialize logging with an existing fd (for daemonized processes)
pub fn initWithFd(fd: posix.fd_t, component: Component) void {
    g_component = component;
    g_log_fd = fd;
}

/// Close the log file
pub fn deinit() void {
    if (g_log_fd >= 0) {
        posix.close(g_log_fd);
        g_log_fd = -1;
    }
}

/// Check if logging is enabled
pub fn isEnabled() bool {
    return g_log_fd >= 0;
}

/// Get the log file descriptor
pub fn getFd() posix.fd_t {
    return g_log_fd;
}

/// Write a log message
pub fn log(level: Level, comptime fmt: []const u8, args: anytype) void {
    logWithUuid(level, null, fmt, args);
}

/// Write a log message with UUID context
pub fn logWithUuid(level: Level, uuid: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
    if (g_log_fd < 0) return;

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    // Timestamp
    const ts = std.time.timestamp();
    const secs = @mod(ts, 86400);
    const hours = @divTrunc(secs, 3600);
    const mins = @divTrunc(@mod(secs, 3600), 60);
    const sec = @mod(secs, 60);

    const ts_str = std.fmt.bufPrint(buf[pos..], "{d:0>2}:{d:0>2}:{d:0>2} ", .{ hours, mins, sec }) catch return;
    pos += ts_str.len;

    // Level
    const level_str = std.fmt.bufPrint(buf[pos..], "[{s}]", .{level.prefix()}) catch return;
    pos += level_str.len;

    // Component
    const comp_str = std.fmt.bufPrint(buf[pos..], "[{s}]", .{g_component.prefix()}) catch return;
    pos += comp_str.len;

    // UUID (short form)
    if (uuid) |u| {
        const short = if (u.len >= 8) u[0..8] else u;
        const uuid_str = std.fmt.bufPrint(buf[pos..], "[{s}]", .{short}) catch return;
        pos += uuid_str.len;
    }

    // Space before message
    buf[pos] = ' ';
    pos += 1;

    // Message
    const msg = std.fmt.bufPrint(buf[pos..], fmt, args) catch return;
    pos += msg.len;

    // Newline
    buf[pos] = '\n';
    pos += 1;

    // Write atomically
    _ = posix.write(g_log_fd, buf[0..pos]) catch {};
}

// Convenience functions
pub fn trace(comptime fmt: []const u8, args: anytype) void {
    log(.trace, fmt, args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}

// With UUID variants
pub fn traceUuid(uuid: []const u8, comptime fmt: []const u8, args: anytype) void {
    logWithUuid(.trace, uuid, fmt, args);
}

pub fn debugUuid(uuid: []const u8, comptime fmt: []const u8, args: anytype) void {
    logWithUuid(.debug, uuid, fmt, args);
}

pub fn infoUuid(uuid: []const u8, comptime fmt: []const u8, args: anytype) void {
    logWithUuid(.info, uuid, fmt, args);
}

pub fn warnUuid(uuid: []const u8, comptime fmt: []const u8, args: anytype) void {
    logWithUuid(.warn, uuid, fmt, args);
}

pub fn errUuid(uuid: []const u8, comptime fmt: []const u8, args: anytype) void {
    logWithUuid(.err, uuid, fmt, args);
}
