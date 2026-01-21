const std = @import("std");
const posix = std.posix;
const core = @import("core");

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;

fn writeJsonEscaped(writer: anytype, value: []const u8) !void {
    for (value) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try writer.writeByte(' ');
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
}

pub fn handleBlockingFloatCompletion(state: *State, pane: *Pane) void {
    const entry = state.pending_float_requests.fetchRemove(pane.uuid) orelse return;
    var conn = core.ipc.Connection{ .fd = entry.value.fd };
    defer conn.close();

    const exit_code = pane.getExitCode();
    var stdout: ?[]u8 = null;
    defer if (stdout) |out| state.allocator.free(out);

    if (entry.value.result_path) |path| {
        const content = std.fs.cwd().readFileAlloc(state.allocator, path, 1024 * 1024) catch null;
        if (content) |buf| {
            const trimmed = std.mem.trimRight(u8, buf, " \n\r\t");
            if (trimmed.len > 0) {
                stdout = state.allocator.dupe(u8, trimmed) catch null;
            }
            state.allocator.free(buf);
        }
        std.fs.cwd().deleteFile(path) catch {};
        state.allocator.free(path);
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(state.allocator);
    var writer = buf.writer(state.allocator);

    writer.print("{{\"type\":\"float_result\",\"uuid\":\"{s}\",\"exit_code\":{d},\"stdout\":\"", .{ pane.uuid, exit_code }) catch return;
    if (stdout) |out| {
        writeJsonEscaped(writer, out) catch return;
    }
    writer.writeAll("\"}\n") catch return;

    conn.send(buf.items) catch {};
}
