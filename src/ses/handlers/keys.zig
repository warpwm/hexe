const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const pod_protocol = core.pod_protocol;
const state = @import("../state.zig");

/// Handle send_keys request - sends keystrokes to a pane via its pod
pub fn handleSendKeys(
    ses_state: *state.SesState,
    conn: *ipc.Connection,
    root: std.json.ObjectMap,
    sendError: *const fn (*ipc.Connection, []const u8) anyerror!void,
) !void {
    std.debug.print("handleSendKeys: starting\n", .{});

    // Get hex-encoded data
    const data_hex = (root.get("hex") orelse return sendError(conn, "missing_hex")).string;
    std.debug.print("handleSendKeys: got hex data len={d}\n", .{data_hex.len});

    // Decode hex
    if (data_hex.len % 2 != 0) {
        return sendError(conn, "invalid_hex");
    }
    const data_len = data_hex.len / 2;
    if (data_len > 4096) {
        return sendError(conn, "data_too_large");
    }
    var data_buf: [4096]u8 = undefined;
    _ = std.fmt.hexToBytes(data_buf[0..data_len], data_hex) catch {
        return sendError(conn, "invalid_hex");
    };
    const data = data_buf[0..data_len];
    std.debug.print("handleSendKeys: decoded {d} bytes\n", .{data_len});

    // Check if broadcast
    const broadcast = if (root.get("broadcast")) |b| b.bool else false;
    std.debug.print("handleSendKeys: broadcast={}\n", .{broadcast});

    if (broadcast) {
        // Send to all attached panes
        std.debug.print("handleSendKeys: broadcasting to all panes\n", .{});
        var sent_count: usize = 0;
        var iter = ses_state.panes.valueIterator();
        while (iter.next()) |pane| {
            std.debug.print("handleSendKeys: checking pane state={}\n", .{pane.state});
            if (pane.state == .attached) {
                std.debug.print("handleSendKeys: sending to pod socket={s}\n", .{pane.pod_socket_path});
                sendToPod(pane.pod_socket_path, data) catch |err| {
                    std.debug.print("handleSendKeys: sendToPod failed: {}\n", .{err});
                    continue;
                };
                sent_count += 1;
                std.debug.print("handleSendKeys: sent to pane, count={d}\n", .{sent_count});
            }
        }
        std.debug.print("handleSendKeys: broadcast done, sending ok\n", .{});
        try conn.sendLine("{\"type\":\"ok\"}");
    } else {
        // Send to specific pane
        const uuid_str = (root.get("uuid") orelse return sendError(conn, "missing_uuid")).string;
        if (uuid_str.len != 32) {
            return sendError(conn, "invalid_uuid");
        }

        var uuid: [32]u8 = undefined;
        @memcpy(&uuid, uuid_str[0..32]);

        const pane = ses_state.panes.get(uuid) orelse {
            try conn.sendLine("{\"type\":\"not_found\"}");
            return;
        };

        sendToPod(pane.pod_socket_path, data) catch {
            return sendError(conn, "pod_send_failed");
        };

        try conn.sendLine("{\"type\":\"ok\"}");
    }
}

/// Send input data to a pod via its socket
fn sendToPod(pod_socket_path: []const u8, data: []const u8) !void {
    // Connect to pod socket
    var pod_client = try ipc.Client.connect(pod_socket_path);
    defer pod_client.close();

    var pod_conn = pod_client.toConnection();

    // Send input frame
    try pod_protocol.writeFrame(&pod_conn, .input, data);
}
