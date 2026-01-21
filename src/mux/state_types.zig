const std = @import("std");
const posix = std.posix;
const core = @import("core");
const pop = @import("pop");

const layout_mod = @import("layout.zig");
const Layout = layout_mod.Layout;

const notification = @import("notification.zig");
const NotificationManager = notification.NotificationManager;

/// Pending action that needs confirmation.
pub const PendingAction = enum {
    exit,
    detach,
    disown,
    close,
    adopt_choose, // Choosing which orphaned pane to adopt
    adopt_confirm, // Confirming destroy vs swap
};

/// A tab contains a layout with splits.
pub const Tab = struct {
    layout: Layout,
    name: []const u8,
    uuid: [32]u8,
    notifications: NotificationManager,
    popups: pop.PopupManager,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16, name: []const u8, notif_cfg: pop.NotificationStyle) Tab {
        return .{
            .layout = Layout.init(allocator, width, height),
            .name = name,
            .uuid = core.ipc.generateUuid(),
            .notifications = NotificationManager.initWithPopConfig(allocator, notif_cfg),
            .popups = pop.PopupManager.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Tab) void {
        self.layout.deinit();
        self.notifications.deinit();
        self.popups.deinit();
    }
};

pub const PendingFloatRequest = struct {
    fd: posix.fd_t,
    result_path: ?[]u8,
};
