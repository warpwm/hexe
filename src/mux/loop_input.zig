const std = @import("std");
const core = @import("core");

const layout_mod = @import("layout.zig");

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;
const SesClient = @import("ses_client.zig").SesClient;

const input = @import("input.zig");
const helpers = @import("helpers.zig");

const actions = @import("loop_actions.zig");
const loop_ipc = @import("loop_ipc.zig");

pub fn handleInput(state: *State, input_bytes: []const u8) void {
    if (input_bytes.len == 0) return;

    const slice = consumeOscReplyFromTerminal(state, input_bytes);
    if (slice.len == 0) return;

    {
        const inp = slice;

        // ==========================================================================
        // LEVEL 1: MUX-level popup blocks EVERYTHING
        // ==========================================================================
        if (state.popups.isBlocked()) {
            if (input.handlePopupInput(&state.popups, inp)) {
                // Check if this was a confirm/picker dialog for pending action
                if (state.pending_action) |action| {
                    switch (action) {
                        .adopt_choose => {
                            // Handle picker result for selecting orphaned pane
                            if (state.popups.getPickerResult()) |selected| {
                                if (selected < state.adopt_orphan_count) {
                                    state.adopt_selected_uuid = state.adopt_orphans[selected].uuid;
                                    // Now show confirm dialog
                                    state.pending_action = .adopt_confirm;
                                    state.popups.clearResults();
                                    state.popups.showConfirm("Destroy current pane?", .{}) catch {};
                                } else {
                                    state.pending_action = null;
                                }
                            } else if (state.popups.wasPickerCancelled()) {
                                state.pending_action = null;
                                state.popups.clearResults();
                            }
                        },
                        .adopt_confirm => {
                            // Handle confirm result for adopt action
                            if (state.popups.getConfirmResult()) |destroy_current| {
                                if (state.adopt_selected_uuid) |uuid| {
                                    actions.performAdopt(state, uuid, destroy_current);
                                }
                            }
                            state.pending_action = null;
                            state.adopt_selected_uuid = null;
                            state.popups.clearResults();
                        },
                        else => {
                            // Handle other confirm dialogs (exit/detach/disown/close)
                            if (state.popups.getConfirmResult()) |confirmed| {
                                if (confirmed) {
                                    switch (action) {
                                        .exit => state.running = false,
                                        .detach => actions.performDetach(state),
                                        .disown => actions.performDisown(state),
                                        .close => actions.performClose(state),
                                        else => {},
                                    }
                                } else {
                                    // User cancelled - if exit was from shell death, respawn
                                    if (action == .exit and state.exit_from_shell_death) {
                                        if (state.currentLayout().getFocusedPane()) |pane| {
                                            switch (pane.backend) {
                                                .local => {
                                                    pane.respawn() catch {
                                                        state.notifications.show("Respawn failed");
                                                    };
                                                    state.skip_dead_check = true;
                                                },
                                                .pod => {
                                                    const cwd = state.getSpawnCwd(pane);
                                                    const old_aux = state.ses_client.getPaneAux(pane.uuid) catch SesClient.PaneAuxInfo{
                                                        .created_from = null,
                                                        .focused_from = null,
                                                    };
                                                    state.ses_client.killPane(pane.uuid) catch {};
                                                    if (state.ses_client.createPane(null, cwd, null, null, null, null)) |result| {
                                                        defer state.allocator.free(result.socket_path);
                                                        var replaced = true;
                                                        pane.replaceWithPod(result.socket_path, result.uuid) catch {
                                                            replaced = false;
                                                        };
                                                        if (replaced) {
                                                            const pane_type: SesClient.PaneType = if (pane.floating) .float else .split;
                                                            const cursor = pane.getCursorPos();
                                                            const cursor_style = pane.vt.getCursorStyle();
                                                            const cursor_visible = pane.vt.isCursorVisible();
                                                            const alt_screen = pane.vt.inAltScreen();
                                                            const layout_path = helpers.getLayoutPath(state, pane) catch null;
                                                            defer if (layout_path) |path| state.allocator.free(path);
                                                            state.ses_client.updatePaneAux(
                                                                pane.uuid,
                                                                pane.floating,
                                                                pane.focused,
                                                                pane_type,
                                                                old_aux.created_from,
                                                                old_aux.focused_from,
                                                                .{ .x = cursor.x, .y = cursor.y },
                                                                cursor_style,
                                                                cursor_visible,
                                                                alt_screen,
                                                                .{ .cols = pane.width, .rows = pane.height },
                                                                pane.getPwd(),
                                                                null,
                                                                null,
                                                                layout_path,
                                                            ) catch {};
                                                            state.skip_dead_check = true;
                                                        } else {
                                                            state.notifications.show("Respawn failed");
                                                        }
                                                    } else |_| {
                                                        state.notifications.show("Respawn failed");
                                                    }
                                                },
                                            }
                                        }
                                    }
                                }
                            }
                            state.pending_action = null;
                            state.exit_from_shell_death = false;
                            state.popups.clearResults();
                        },
                    }
                } else {
                    loop_ipc.sendPopResponse(state);
                }
            }
            state.needs_render = true;
            return;
        }

        // ==========================================================================
        // LEVEL 2: TAB-level popup - allows tab switching, blocks rest
        // ==========================================================================
        const current_tab = &state.tabs.items[state.active_tab];
        if (current_tab.popups.isBlocked()) {
            // Allow tab switching (Alt+N, Alt+P) - also support fallback keys for Alt+>/<'
            if (inp.len >= 2 and inp[0] == 0x1b and inp[1] != '[' and inp[1] != 'O') {
                const cfg = &state.config;
                const is_next = inp[1] == cfg.tabs.key_next or (cfg.tabs.key_next == '>' and inp[1] == '.');
                const is_prev = inp[1] == cfg.tabs.key_prev or (cfg.tabs.key_prev == '<' and inp[1] == ',');
                if (is_next or is_prev) {
                    // Allow tab switch.
                    if (handleAltKey(state, inp[1])) {
                        return;
                    }
                }
            }
            // Block everything else - handle popup input.
            if (input.handlePopupInput(&current_tab.popups, inp)) {
                loop_ipc.sendPopResponse(state);
            }
            state.needs_render = true;
            return;
        }

        var i: usize = 0;
        while (i < inp.len) {
            // Check for Alt+key (ESC followed by key).
            if (inp[i] == 0x1b and i + 1 < inp.len) {
                const next = inp[i + 1];
                // Check for CSI sequences (ESC [).
                if (next == '[' and i + 2 < inp.len) {
                    // Handle Alt+Arrow for directional navigation: ESC [ 1 ; 3 <dir>
                    if (handleAltArrow(state, inp[i..])) |consumed| {
                        i += consumed;
                        continue;
                    }
                    // Handle scroll keys.
                    if (handleScrollKeys(state, inp[i..])) |consumed| {
                        i += consumed;
                        continue;
                    }
                }
                // Make sure it's not an actual escape sequence (like arrow keys).
                if (next != '[' and next != 'O') {
                    if (handleAltKey(state, next)) {
                        i += 2;
                        continue;
                    }
                }
            }

            // Check for Ctrl+Q to quit.
            if (inp[i] == 0x11) {
                state.running = false;
                return;
            }

            // ==========================================================================
            // LEVEL 3: PANE-level popup - blocks only input to that specific pane
            // ==========================================================================
            if (state.active_floating) |idx| {
                const fpane = state.floats.items[idx];
                // Check tab ownership for tab-bound floats.
                const can_interact = if (fpane.parent_tab) |parent|
                    parent == state.active_tab
                else
                    true;

                if (fpane.isVisibleOnTab(state.active_tab) and can_interact) {
                    // Check if this float pane has a blocking popup.
                    if (fpane.popups.isBlocked()) {
                        if (input.handlePopupInput(&fpane.popups, inp[i..])) {
                            loop_ipc.sendPopResponse(state);
                        }
                        state.needs_render = true;
                        return;
                    }
                    if (fpane.isScrolled()) {
                        fpane.scrollToBottom();
                        state.needs_render = true;
                    }
                    fpane.write(inp[i..]) catch {};
                } else {
                    // Can't input to tab-bound float on wrong tab, forward to tiled pane.
                    if (state.currentLayout().getFocusedPane()) |pane| {
                        // Check if this pane has a blocking popup.
                        if (pane.popups.isBlocked()) {
                            if (input.handlePopupInput(&pane.popups, inp[i..])) {
                                loop_ipc.sendPopResponse(state);
                            }
                            state.needs_render = true;
                            return;
                        }
                        if (pane.isScrolled()) {
                            pane.scrollToBottom();
                            state.needs_render = true;
                        }
                        pane.write(inp[i..]) catch {};
                    }
                }
            } else if (state.currentLayout().getFocusedPane()) |pane| {
                // Check if this pane has a blocking popup.
                if (pane.popups.isBlocked()) {
                    if (input.handlePopupInput(&pane.popups, inp[i..])) {
                        loop_ipc.sendPopResponse(state);
                    }
                    state.needs_render = true;
                    return;
                }
                if (pane.isScrolled()) {
                    pane.scrollToBottom();
                    state.needs_render = true;
                }
                pane.write(inp[i..]) catch {};
            }
            return;
        }
    }
}

fn consumeOscReplyFromTerminal(state: *State, inp: []const u8) []const u8 {
    // Only do work if we previously forwarded a query.
    if (state.osc_reply_target_uuid == null and !state.osc_reply_in_progress) return inp;

    const ESC: u8 = 0x1b;
    const BEL: u8 = 0x07;

    // Start capture only if the input begins with an OSC response.
    if (!state.osc_reply_in_progress) {
        if (inp.len < 2 or inp[0] != ESC or inp[1] != ']') return inp;
        state.osc_reply_in_progress = true;
        state.osc_reply_prev_esc = false;
        state.osc_reply_buf.clearRetainingCapacity();
    }

    var i: usize = 0;
    while (i < inp.len) : (i += 1) {
        const b = inp[i];
        state.osc_reply_buf.append(state.allocator, b) catch {
            // Drop on allocation error.
            state.osc_reply_in_progress = false;
            state.osc_reply_prev_esc = false;
            state.osc_reply_target_uuid = null;
            state.osc_reply_buf.clearRetainingCapacity();
            return inp[i + 1 ..];
        };

        var done = false;
        if (b == BEL) {
            done = true;
        } else if (state.osc_reply_prev_esc and b == '\\') {
            done = true;
        }
        state.osc_reply_prev_esc = (b == ESC);

        if (state.osc_reply_buf.items.len > 64 * 1024) {
            state.osc_reply_in_progress = false;
            state.osc_reply_prev_esc = false;
            state.osc_reply_target_uuid = null;
            state.osc_reply_buf.clearRetainingCapacity();
            return inp[i + 1 ..];
        }

        if (done) {
            if (state.osc_reply_target_uuid) |uuid| {
                if (state.findPaneByUuid(uuid)) |pane| {
                    pane.write(state.osc_reply_buf.items) catch {};
                }
            }

            state.osc_reply_in_progress = false;
            state.osc_reply_prev_esc = false;
            state.osc_reply_target_uuid = null;
            state.osc_reply_buf.clearRetainingCapacity();

            return inp[i + 1 ..];
        }
    }

    // Consumed everything into the pending reply buffer.
    return &[_]u8{};
}

/// Handle Alt+Arrow for directional pane navigation.
/// Sequence: ESC [ 1 ; 3 <A/B/C/D> (Alt+Up/Down/Right/Left)
/// Returns number of bytes consumed, or null if not an Alt+Arrow sequence.
fn handleAltArrow(state: *State, inp: []const u8) ?usize {
    // Check for ESC [ 1 ; 3 <dir> pattern (6 bytes)
    if (inp.len >= 6 and inp[0] == 0x1b and inp[1] == '[' and
        inp[2] == '1' and inp[3] == ';' and inp[4] == '3')
    {
        const dir: ?layout_mod.Layout.Direction = switch (inp[5]) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            else => null,
        };

        if (dir) |d| {
            const old_uuid = state.getCurrentFocusedUuid();

            // Get cursor position from current pane for smarter direction targeting.
            var cursor_x: u16 = 0;
            var cursor_y: u16 = 0;
            var have_cursor = false;
            if (state.active_floating) |idx| {
                const pos = state.floats.items[idx].getCursorPos();
                cursor_x = pos.x;
                cursor_y = pos.y;
                have_cursor = true;
            } else if (state.currentLayout().getFocusedPane()) |pane| {
                const pos = pane.getCursorPos();
                cursor_x = pos.x;
                cursor_y = pos.y;
                have_cursor = true;
            }

            // Unfocus current pane.
            if (state.active_floating) |idx| {
                state.syncPaneUnfocus(state.floats.items[idx]);
                state.active_floating = null;
            } else if (state.currentLayout().getFocusedPane()) |old_pane| {
                state.syncPaneUnfocus(old_pane);
            }

            // Navigate in direction using cursor position for alignment.
            const cursor_pos: ?layout_mod.CursorPos = if (have_cursor) .{ .x = cursor_x, .y = cursor_y } else null;
            state.currentLayout().focusDirection(d, cursor_pos);

            // Sync focus to new pane.
            if (state.currentLayout().getFocusedPane()) |new_pane| {
                state.syncPaneFocus(new_pane, old_uuid);
            }

            state.needs_render = true;
            return 6;
        }
    }

    return null;
}

/// Handle scroll-related escape sequences.
/// Returns number of bytes consumed, or null if not a scroll sequence.
fn handleScrollKeys(state: *State, inp: []const u8) ?usize {
    // Must start with ESC [
    if (inp.len < 3 or inp[0] != 0x1b or inp[1] != '[') return null;

    // Choose active pane (float or tiled)
    const pane: ?*Pane = if (state.active_floating) |idx|
        state.floats.items[idx]
    else
        state.currentLayout().getFocusedPane();
    if (pane == null) return null;
    const p = pane.?;

    // PageUp: ESC [ 5 ~
    if (inp.len >= 4 and inp[2] == '5' and inp[3] == '~') {
        p.scrollUp(5);
        state.needs_render = true;
        return 4;
    }

    // PageDown: ESC [ 6 ~
    if (inp.len >= 4 and inp[2] == '6' and inp[3] == '~') {
        p.scrollDown(5);
        state.needs_render = true;
        return 4;
    }

    // Home: ESC [ H or ESC [ 1 ~
    if (inp.len >= 3 and inp[2] == 'H') {
        p.scrollToTop();
        state.needs_render = true;
        return 3;
    }
    if (inp.len >= 4 and inp[2] == '1' and inp[3] == '~') {
        p.scrollToTop();
        state.needs_render = true;
        return 4;
    }

    // End: ESC [ F or ESC [ 4 ~
    if (inp.len >= 3 and inp[2] == 'F') {
        p.scrollToBottom();
        state.needs_render = true;
        return 3;
    }
    if (inp.len >= 4 and inp[2] == '4' and inp[3] == '~') {
        p.scrollToBottom();
        state.needs_render = true;
        return 4;
    }

    // Shift+Up: ESC [ 1 ; 2 A - scroll up one line
    if (inp.len >= 6 and inp[2] == '1' and inp[3] == ';' and inp[4] == '2' and inp[5] == 'A') {
        p.scrollUp(1);
        state.needs_render = true;
        return 6;
    }

    // Shift+Down: ESC [ 1 ; 2 B - scroll down one line
    if (inp.len >= 6 and inp[2] == '1' and inp[3] == ';' and inp[4] == '2' and inp[5] == 'B') {
        p.scrollDown(1);
        state.needs_render = true;
        return 6;
    }

    return null;
}

fn handleAltKey(state: *State, key: u8) bool {
    const cfg = &state.config;

    if (key == cfg.key_quit) {
        if (cfg.confirm_on_exit) {
            state.pending_action = .exit;
            state.popups.showConfirm("Exit mux?", .{}) catch {};
            state.needs_render = true;
        } else {
            state.running = false;
        }
        return true;
    }

    // Disown pane - orphans current pane in ses, spawns new shell in same place.
    if (key == cfg.key_disown) {
        // Get the current pane (float or tiled).
        const current_pane: ?*Pane = if (state.active_floating) |idx|
            state.floats.items[idx]
        else
            state.currentLayout().getFocusedPane();

        // Block disown for sticky floats only.
        if (current_pane) |p| {
            if (p.sticky) {
                state.notifications.show("Cannot disown sticky float");
                state.needs_render = true;
                return true;
            }
        }

        if (cfg.confirm_on_disown) {
            state.pending_action = .disown;
            state.popups.showConfirm("Disown pane?", .{}) catch {};
            state.needs_render = true;
        } else {
            actions.performDisown(state);
        }
        return true;
    }

    // Adopt orphaned pane - interactive flow with picker and confirm.
    if (key == cfg.key_adopt) {
        actions.startAdoptFlow(state);
        return true;
    }

    // Split keys.
    const split_h_key = cfg.splits.key_split_h;
    const split_v_key = cfg.splits.key_split_v;

    if (key == split_h_key) {
        const parent_uuid = state.getCurrentFocusedUuid();
        // Refresh CWD from ses for pod panes before splitting.
        const cwd = if (state.currentLayout().getFocusedPane()) |p| state.refreshPaneCwd(p) else null;
        if (state.currentLayout().splitFocused(.horizontal, cwd) catch null) |new_pane| {
            state.syncPaneAux(new_pane, parent_uuid);
        }
        state.needs_render = true;
        state.syncStateToSes();
        return true;
    }

    if (key == split_v_key) {
        const parent_uuid = state.getCurrentFocusedUuid();
        // Refresh CWD from ses for pod panes before splitting.
        const cwd = if (state.currentLayout().getFocusedPane()) |p| state.refreshPaneCwd(p) else null;
        if (state.currentLayout().splitFocused(.vertical, cwd) catch null) |new_pane| {
            state.syncPaneAux(new_pane, parent_uuid);
        }
        state.needs_render = true;
        state.syncStateToSes();
        return true;
    }

    // Alt+t = new tab.
    if (key == cfg.tabs.key_new) {
        state.active_floating = null;
        state.createTab() catch {};
        state.needs_render = true;
        return true;
    }

    // Alt+n = next tab (also support Alt+. as fallback for Alt+>).
    if (key == cfg.tabs.key_next or (cfg.tabs.key_next == '>' and key == '.')) {
        const old_uuid = state.getCurrentFocusedUuid();
        if (state.active_floating) |idx| {
            if (idx < state.floats.items.len) {
                const fp = state.floats.items[idx];
                // Tab-bound floats lose focus when switching tabs.
                if (fp.parent_tab != null) {
                    state.syncPaneUnfocus(fp);
                    state.active_floating = null;
                }
            }
        } else if (state.currentLayout().getFocusedPane()) |old_pane| {
            state.syncPaneUnfocus(old_pane);
        }
        state.nextTab();
        if (state.active_floating == null) {
            if (state.currentLayout().getFocusedPane()) |new_pane| {
                state.syncPaneFocus(new_pane, old_uuid);
            }
        }
        state.needs_render = true;
        return true;
    }

    // Alt+p = previous tab (also support Alt+, as fallback for Alt+<).
    if (key == cfg.tabs.key_prev or (cfg.tabs.key_prev == '<' and key == ',')) {
        const old_uuid = state.getCurrentFocusedUuid();
        if (state.active_floating) |idx| {
            if (idx < state.floats.items.len) {
                const fp = state.floats.items[idx];
                // Tab-bound floats lose focus when switching tabs.
                if (fp.parent_tab != null) {
                    state.syncPaneUnfocus(fp);
                    state.active_floating = null;
                }
            }
        } else if (state.currentLayout().getFocusedPane()) |old_pane| {
            state.syncPaneUnfocus(old_pane);
        }
        state.prevTab();
        if (state.active_floating == null) {
            if (state.currentLayout().getFocusedPane()) |new_pane| {
                state.syncPaneFocus(new_pane, old_uuid);
            }
        }
        state.needs_render = true;
        return true;
    }

    // Alt+x (configurable) = close current float/tab (or quit if last tab).
    if (key == cfg.tabs.key_close) {
        if (cfg.confirm_on_close) {
            state.pending_action = .close;
            const msg = if (state.active_floating != null) "Close float?" else "Close tab?";
            state.popups.showConfirm(msg, .{}) catch {};
            state.needs_render = true;
        } else {
            actions.performClose(state);
        }
        return true;
    }

    // Alt+d = detach whole mux - keeps all panes alive in ses for --attach.
    if (key == cfg.tabs.key_detach) {
        if (cfg.confirm_on_detach) {
            state.pending_action = .detach;
            state.popups.showConfirm("Detach session?", .{}) catch {};
            state.needs_render = true;
            return true;
        }
        actions.performDetach(state);
        return true;
    }

    // Alt+space - toggle floating focus (always space).
    if (key == ' ') {
        if (state.floats.items.len > 0) {
            const old_uuid = state.getCurrentFocusedUuid();
            if (state.active_floating) |idx| {
                if (idx < state.floats.items.len) {
                    state.syncPaneUnfocus(state.floats.items[idx]);
                }
                state.active_floating = null;
                if (state.currentLayout().getFocusedPane()) |new_pane| {
                    state.syncPaneFocus(new_pane, old_uuid);
                }
            } else {
                // Find first float valid for current tab.
                var first_valid: ?usize = null;
                for (state.floats.items, 0..) |fp, fi| {
                    // Skip tab-bound floats on wrong tab.
                    if (fp.parent_tab) |parent| {
                        if (parent != state.active_tab) continue;
                    }
                    first_valid = fi;
                    break;
                }

                if (first_valid) |valid_idx| {
                    if (state.currentLayout().getFocusedPane()) |old_pane| {
                        state.syncPaneUnfocus(old_pane);
                    }
                    state.active_floating = valid_idx;
                    state.syncPaneFocus(state.floats.items[valid_idx], old_uuid);
                }
            }
            state.needs_render = true;
        }
        return true;
    }

    // Check for named float keys from config.
    if (cfg.getFloatByKey(key)) |float_def| {
        actions.toggleNamedFloat(state, float_def);
        state.needs_render = true;
        return true;
    }

    return false;
}
