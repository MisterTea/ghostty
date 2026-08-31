//! INIT_STATE JSON layout from `htmd`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const protocol = @import("protocol.zig");

pub const Tab = struct {
    id: []const u8,
    order: i64 = 0,
    pane_or_split: []const u8,
};

pub const Pane = struct {
    id: []const u8,
};

pub const Split = struct {
    id: []const u8,
    vertical: bool,
    panes_or_splits: []const []const u8,
    sizes: []const f64,
};

pub const InitState = struct {
    arena: ArenaAllocator,
    shell: []const u8,
    tabs: []Tab,
    panes: []Pane,
    splits: []Split,

    pub fn deinit(self: *InitState) void {
        self.arena.deinit();
    }

    pub fn tabCount(self: *const InitState) usize {
        return self.tabs.len;
    }

    pub fn tabByOrder(self: *const InitState, order: i64) ?*const Tab {
        for (self.tabs) |*tab| {
            if (tab.order == order) return tab;
        }
        return null;
    }

    pub fn splitById(self: *const InitState, id: []const u8) ?*const Split {
        for (self.splits) |*split| {
            if (std.mem.eql(u8, split.id, id)) return split;
        }
        return null;
    }

    pub fn paneById(self: *const InitState, id: []const u8) ?*const Pane {
        for (self.panes) |*pane| {
            if (std.mem.eql(u8, pane.id, id)) return pane;
        }
        return null;
    }

    /// Walk a pane-or-split id to the first leaf pane UUID.
    pub fn firstPaneId(self: *const InitState, pane_or_split: []const u8) ?[]const u8 {
        if (self.paneById(pane_or_split) != null) return pane_or_split;
        const split = self.splitById(pane_or_split) orelse return null;
        if (split.panes_or_splits.len == 0) return null;
        return self.firstPaneId(split.panes_or_splits[0]);
    }

    pub fn parseUuid(id: []const u8) ?protocol.Uuid {
        return protocol.parseUuid(id);
    }
};

pub fn parse(alloc: Allocator, json: []const u8) !InitState {
    var arena = ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidInitState,
    };

    const shell = shell: {
        const v = root.get("shell") orelse break :shell "";
        break :shell switch (v) {
            .string => |s| s,
            else => "",
        };
    };

    var tabs: std.ArrayList(Tab) = .empty;
    if (root.get("tabs")) |tabs_v| {
        const obj = switch (tabs_v) {
            .object => |o| o,
            else => return error.InvalidInitState,
        };
        var it = obj.iterator();
        while (it.next()) |entry| {
            const t = try parseTab(entry.value_ptr.*);
            try tabs.append(a, t);
        }
    }

    var panes: std.ArrayList(Pane) = .empty;
    if (root.get("panes")) |panes_v| {
        const obj = switch (panes_v) {
            .object => |o| o,
            else => return error.InvalidInitState,
        };
        var it = obj.iterator();
        while (it.next()) |entry| {
            const p = try parsePane(entry.key_ptr.*, entry.value_ptr.*);
            try panes.append(a, p);
        }
    }

    var splits: std.ArrayList(Split) = .empty;
    if (root.get("splits")) |splits_v| {
        const obj = switch (splits_v) {
            .object => |o| o,
            else => return error.InvalidInitState,
        };
        var it = obj.iterator();
        while (it.next()) |entry| {
            const s = try parseSplit(a, entry.key_ptr.*, entry.value_ptr.*);
            try splits.append(a, s);
        }
    }

    return .{
        .arena = arena,
        .shell = shell,
        .tabs = tabs.items,
        .panes = panes.items,
        .splits = splits.items,
    };
}

fn parseTab(value: std.json.Value) !Tab {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidInitState,
    };
    const id = switch (obj.get("id") orelse return error.InvalidInitState) {
        .string => |s| s,
        else => return error.InvalidInitState,
    };
    const pane_or_split = switch (obj.get("paneOrSplit") orelse return error.InvalidInitState) {
        .string => |s| s,
        else => return error.InvalidInitState,
    };
    const order: i64 = order: {
        const v = obj.get("order") orelse break :order 0;
        break :order switch (v) {
            .integer => |n| n,
            .float => |n| @intFromFloat(n),
            else => 0,
        };
    };
    return .{
        .id = id,
        .order = order,
        .pane_or_split = pane_or_split,
    };
}

fn parsePane(key: []const u8, value: std.json.Value) !Pane {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidInitState,
    };
    const id = switch (obj.get("id") orelse std.json.Value{ .string = key }) {
        .string => |s| s,
        else => key,
    };
    return .{ .id = id };
}

fn parseSplit(alloc: Allocator, key: []const u8, value: std.json.Value) !Split {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidInitState,
    };
    const id = switch (obj.get("id") orelse std.json.Value{ .string = key }) {
        .string => |s| s,
        else => key,
    };
    const vertical = switch (obj.get("vertical") orelse std.json.Value{ .bool = false }) {
        .bool => |b| b,
        else => false,
    };

    var children: std.ArrayList([]const u8) = .empty;
    if (obj.get("panesOrSplits")) |arr_v| {
        const arr = switch (arr_v) {
            .array => |a| a,
            else => return error.InvalidInitState,
        };
        for (arr.items) |item| {
            try children.append(alloc, switch (item) {
                .string => |s| s,
                else => return error.InvalidInitState,
            });
        }
    }

    var sizes: std.ArrayList(f64) = .empty;
    if (obj.get("sizes")) |arr_v| {
        const arr = switch (arr_v) {
            .array => |a| a,
            else => return error.InvalidInitState,
        };
        for (arr.items) |item| {
            try sizes.append(alloc, switch (item) {
                .float => |n| n,
                .integer => |n| @floatFromInt(n),
                else => return error.InvalidInitState,
            });
        }
    }

    return .{
        .id = id,
        .vertical = vertical,
        .panes_or_splits = children.items,
        .sizes = sizes.items,
    };
}

test "parse INIT_STATE with a single tab and pane" {
    const json =
        \\{"shell":"/bin/zsh","tabs":{"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","order":0,"paneOrSplit":"11111111-2222-3333-4444-555555555555"}},"panes":{"11111111-2222-3333-4444-555555555555":{"id":"11111111-2222-3333-4444-555555555555"}},"splits":{}}
    ;
    var state = try parse(testing.allocator, json);
    defer state.deinit();
    try testing.expectEqualStrings("/bin/zsh", state.shell);
    try testing.expectEqual(@as(usize, 1), state.tabs.len);
    try testing.expectEqual(@as(i64, 0), state.tabs[0].order);
    try testing.expectEqual(@as(usize, 1), state.panes.len);
    try testing.expectEqualStrings(
        "11111111-2222-3333-4444-555555555555",
        state.firstPaneId(state.tabs[0].pane_or_split).?,
    );
}

test "parse INIT_STATE with a vertical split" {
    const json =
        \\{"shell":"/bin/sh","tabs":{"t0":{"id":"t0","order":0,"paneOrSplit":"s0"}},"panes":{"p0":{"id":"p0"},"p1":{"id":"p1"}},"splits":{"s0":{"id":"s0","vertical":true,"panesOrSplits":["p0","p1"],"sizes":[0.5,0.5]}}}
    ;
    var state = try parse(testing.allocator, json);
    defer state.deinit();
    const split = state.splitById("s0").?;
    try testing.expect(split.vertical);
    try testing.expectEqual(@as(usize, 2), split.panes_or_splits.len);
    try testing.expectEqualStrings("p0", state.firstPaneId("s0").?);
    try testing.expectEqualStrings("p1", split.panes_or_splits[1]);
}
