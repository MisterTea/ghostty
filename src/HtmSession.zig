//! Window-scoped HTM session: maps `htmd` pane UUIDs onto Ghostty surfaces
//! and rebuilds tabs/splits from INIT_STATE.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Surface = @import("Surface.zig");
const apprt = @import("apprt.zig");
const termio = @import("termio.zig");
const terminal = @import("terminal/main.zig");
const htm = terminal.htm;

const log = std.log.scoped(.htm_session);

pub const Pending = enum {
    none,
    tab,
    split_vertical,
    split_horizontal,
};

pub const Session = struct {
    alloc: Allocator,
    leader: *Surface,
    waiting_for_init: bool = false,
    next_pane_id: ?htm.Uuid = null,
    pending: Pending = .none,
    pending_source: ?*Surface = null,
    pane_to_surface: std.AutoHashMapUnmanaged(htm.Uuid, *Surface) = .empty,
    surface_to_pane: std.AutoHashMapUnmanaged(u64, htm.Uuid) = .empty,

    pub fn init(alloc: Allocator, leader: *Surface) Session {
        return .{
            .alloc = alloc,
            .leader = leader,
        };
    }

    pub fn deinit(self: *Session) void {
        self.pane_to_surface.deinit(self.alloc);
        self.surface_to_pane.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn isLeader(self: *const Session, surface: *const Surface) bool {
        return self.leader == surface;
    }

    pub fn isFollower(self: *const Session, surface: *const Surface) bool {
        return self.surface_to_pane.contains(surface.id);
    }

    pub fn writeToLeader(self: *Session, packet: []const u8) void {
        const msg = termio.Message.writeReq(self.alloc, packet) catch |err| {
            log.warn("failed to queue HTM packet to leader err={}", .{err});
            return;
        };
        self.leader.io.queueMessage(msg, .unlocked);
    }

    pub fn registerPane(self: *Session, pane_id: htm.Uuid, surface: *Surface) void {
        self.pane_to_surface.put(self.alloc, pane_id, surface) catch |err| {
            log.warn("failed to map HTM pane err={}", .{err});
            return;
        };
        self.surface_to_pane.put(self.alloc, surface.id, pane_id) catch |err| {
            log.warn("failed to map HTM surface err={}", .{err});
            return;
        };
    }

    pub fn unregisterSurface(self: *Session, surface: *Surface) void {
        if (self.surface_to_pane.fetchRemove(surface.id)) |kv| {
            _ = self.pane_to_surface.remove(kv.value);
        }
    }

    pub fn surfaceForPane(self: *const Session, pane_id: htm.Uuid) ?*Surface {
        return self.pane_to_surface.get(pane_id);
    }

    pub fn paneForSurface(self: *const Session, surface: *const Surface) ?htm.Uuid {
        return self.surface_to_pane.get(surface.id);
    }

    /// Assign a pane id for a newly created follower surface.
    pub fn takePaneId(self: *Session) htm.Uuid {
        if (self.next_pane_id) |id| {
            self.next_pane_id = null;
            return id;
        }
        return htm.generateUuid();
    }

    pub fn shouldCreateFollower(self: *const Session) bool {
        return self.pending != .none;
    }

    /// Rebuild Ghostty tabs/splits to match INIT_STATE. Must run on the
    /// app thread. New surfaces created here consume `next_pane_id` and
    /// do not send NEW_TAB/NEW_SPLIT.
    pub fn applyLayout(self: *Session, init_state: *const htm.InitState) void {
        self.waiting_for_init = true;
        defer self.waiting_for_init = false;

        var max_order: i64 = -1;
        for (init_state.tabs) |tab| {
            if (tab.order > max_order) max_order = tab.order;
        }

        var prev: *Surface = self.leader;
        var order: i64 = 0;
        while (order <= max_order) : (order += 1) {
            const tab = init_state.tabByOrder(order) orelse continue;
            const first_id = init_state.firstPaneId(tab.pane_or_split) orelse {
                log.warn("HTM tab has no leaf pane id={s}", .{tab.id});
                continue;
            };
            const pane_uuid = htm.parseUuid(first_id) orelse {
                log.warn("HTM pane id is not a UUID: {s}", .{first_id});
                continue;
            };
            self.next_pane_id = pane_uuid;
            self.pending = .tab;
            self.pending_source = self.leader;
            _ = prev.rt_app.performAction(
                .{ .surface = prev },
                .new_tab,
                {},
            ) catch |err| {
                log.warn("failed to create HTM tab err={}", .{err});
                self.next_pane_id = null;
                self.pending = .none;
                self.pending_source = null;
                continue;
            };
            const first_surface = self.surfaceForPane(pane_uuid) orelse {
                log.warn("HTM tab surface was not registered", .{});
                continue;
            };
            if (init_state.splitById(tab.pane_or_split)) |split| {
                self.createSplit(init_state, split);
            }
            prev = first_surface;
        }
        self.pending = .none;
        self.pending_source = null;
        self.next_pane_id = null;
    }

    fn createSplit(self: *Session, init_state: *const htm.InitState, split: *const htm.Split) void {
        var i: usize = 1;
        while (i < split.panes_or_splits.len) : (i += 1) {
            const source_id = init_state.firstPaneId(split.panes_or_splits[i - 1]) orelse continue;
            const new_id = init_state.firstPaneId(split.panes_or_splits[i]) orelse continue;
            const source_uuid = htm.parseUuid(source_id) orelse continue;
            const new_uuid = htm.parseUuid(new_id) orelse continue;
            const source = self.surfaceForPane(source_uuid) orelse continue;
            self.next_pane_id = new_uuid;
            self.pending = if (split.vertical) .split_vertical else .split_horizontal;
            self.pending_source = source;
            const direction: apprt.action.SplitDirection = if (split.vertical) .right else .down;
            _ = source.rt_app.performAction(
                .{ .surface = source },
                .new_split,
                direction,
            ) catch |err| {
                log.warn("failed to create HTM split err={}", .{err});
                self.next_pane_id = null;
                self.pending = .none;
                self.pending_source = null;
            };
        }

        for (split.panes_or_splits) |child| {
            if (init_state.splitById(child)) |inner| {
                self.createSplit(init_state, inner);
            }
        }
    }

    /// Close every follower surface. Leader remains.
    pub fn closeFollowers(self: *Session) void {
        var surfaces: std.ArrayList(*Surface) = .empty;
        defer surfaces.deinit(self.alloc);
        var it = self.pane_to_surface.valueIterator();
        while (it.next()) |ptr| {
            const surface = ptr.*;
            if (surface == self.leader) continue;
            surfaces.append(self.alloc, surface) catch continue;
        }
        self.pane_to_surface.clearRetainingCapacity();
        self.surface_to_pane.clearRetainingCapacity();
        for (surfaces.items) |surface| {
            surface.close();
        }
    }
};
