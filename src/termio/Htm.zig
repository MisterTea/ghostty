//! HTM follower termio backend. No PTY or subprocess: pane I/O is multiplexed
//! through the leader surface that owns the `htm` client.

const std = @import("std");
const Allocator = std.mem.Allocator;
const App = @import("../App.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;
const htm = terminal.htm;

const log = std.log.scoped(.io_htm);

pub const Htm = @This();

app: *App,
pane_id: htm.Uuid,

pub fn init(app: *App, pane_id: htm.Uuid) Htm {
    return .{
        .app = app,
        .pane_id = pane_id,
    };
}

pub fn deinit(self: *Htm) void {
    _ = self;
}

pub fn initTerminal(self: *Htm, term: *terminal.Terminal) void {
    _ = self;
    _ = term;
}

pub fn threadEnter(
    self: *Htm,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = self;
    _ = alloc;
    _ = io;
    td.backend = .{ .htm = .{} };
}

pub fn threadExit(self: *Htm, td: *termio.Termio.ThreadData) void {
    _ = self;
    _ = td;
}

pub fn focusGained(
    self: *Htm,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
}

pub fn resize(
    self: *Htm,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    _ = screen_size;
    const session = if (self.app.htm) |*s| s else return;
    const packet = htm.encodeResizePane(
        self.app.alloc,
        @intCast(grid_size.columns),
        @intCast(grid_size.rows),
        self.pane_id,
    ) catch |err| {
        log.warn("failed to encode HTM resize packet err={}", .{err});
        return;
    };
    defer self.app.alloc.free(packet);
    session.writeToLeader(packet);
}

pub fn queueWrite(
    self: *Htm,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = td;
    _ = linefeed;
    const session = if (self.app.htm) |*s| s else return;
    const packet = htm.encodeInsertKeys(alloc, self.pane_id, data) catch |err| {
        log.warn("failed to encode HTM insert_keys packet err={}", .{err});
        return;
    };
    defer alloc.free(packet);
    session.writeToLeader(packet);
}

pub fn childExitedAbnormally(
    self: *Htm,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

pub fn getProcessInfo(self: *Htm, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    _ = self;
    return null;
}

pub const ThreadData = struct {
    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};

pub const Config = struct {
    app: *App,
    pane_id: htm.Uuid,
};
