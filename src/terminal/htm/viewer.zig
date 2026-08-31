//! HTM packet dispatcher. Turns framed packets into UI/IO actions.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const state = @import("state.zig");

const log = std.log.scoped(.terminal_htm_viewer);

pub const Action = union(enum) {
    exit,
    invalid_length,
    debug_log: []const u8,
    pane_output: struct {
        pane_id: protocol.Uuid,
        data: []const u8,
    },
    close_pane: protocol.Uuid,
    sync_layout: []const u8,
};

pub const Viewer = struct {
    alloc: Allocator,
    hold_packets: bool = false,

    pub fn init(alloc: Allocator) Viewer {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Viewer) void {
        _ = self;
    }

    /// Process a parsed packet. Payload slices in the returned action are
    /// allocated with `alloc` when they need to outlive the packet buffer
    /// (decoded bytes / copied JSON). Caller owns those allocations.
    pub fn process(
        self: *Viewer,
        alloc: Allocator,
        packet: protocol.Packet,
    ) (Allocator.Error || error{InvalidBase64})!?Action {
        _ = self;
        if (packet.invalid_length) return .invalid_length;

        return switch (packet.header) {
            .session_end => .exit,
            .init_state => .{
                .sync_layout = try alloc.dupe(u8, packet.payload),
            },
            .append_to_pane => append: {
                const pane_id = protocol.parseUuid(packet.payload) orelse {
                    log.warn("APPEND_TO_PANE missing pane id", .{});
                    break :append null;
                };
                const encoded = packet.payload[protocol.UUID_LENGTH..];
                const data = protocol.decodeBase64(alloc, encoded) catch |err| {
                    log.warn("APPEND_TO_PANE invalid base64 err={}", .{err});
                    break :append null;
                };
                break :append .{
                    .pane_output = .{
                        .pane_id = pane_id,
                        .data = data,
                    },
                };
            },
            .debug_log => debug: {
                const data = protocol.decodeBase64(alloc, packet.payload) catch |err| {
                    log.warn("DEBUG_LOG invalid base64 err={}", .{err});
                    break :debug null;
                };
                break :debug .{ .debug_log = data };
            },
            .server_close_pane => close: {
                const pane_id = protocol.parseUuid(packet.payload) orelse {
                    log.warn("SERVER_CLOSE_PANE missing pane id", .{});
                    break :close null;
                };
                break :close .{ .close_pane = pane_id };
            },
            else => {
                log.debug("ignoring HTM packet header={c}", .{@intFromEnum(packet.header)});
                return null;
            },
        };
    }
};

test "viewer emits sync_layout for INIT_STATE" {
    var viewer = Viewer.init(testing.allocator);
    defer viewer.deinit();
    const json = "{\"panes\":{}}";
    const action = try viewer.process(testing.allocator, .{
        .header = .init_state,
        .payload = json,
    });
    defer if (action) |a| switch (a) {
        .sync_layout => |s| testing.allocator.free(s),
        .debug_log => |s| testing.allocator.free(s),
        .pane_output => |p| testing.allocator.free(p.data),
        else => {},
    };
    try testing.expect(action != null);
    try testing.expectEqualStrings(json, action.?.sync_layout);
}

test "viewer emits pane_output for APPEND_TO_PANE" {
    var viewer = Viewer.init(testing.allocator);
    defer viewer.deinit();

    const pane = "11111111-2222-3333-4444-555555555555";
    const raw = "hello";
    const b64_len = std.base64.standard.Encoder.calcSize(raw.len);
    var payload = try testing.allocator.alloc(u8, protocol.UUID_LENGTH + b64_len);
    defer testing.allocator.free(payload);
    @memcpy(payload[0..protocol.UUID_LENGTH], pane);
    _ = std.base64.standard.Encoder.encode(payload[protocol.UUID_LENGTH..], raw);

    const action = try viewer.process(testing.allocator, .{
        .header = .append_to_pane,
        .payload = payload,
    });
    defer if (action) |a| switch (a) {
        .pane_output => |p| testing.allocator.free(p.data),
        .sync_layout => |s| testing.allocator.free(s),
        .debug_log => |s| testing.allocator.free(s),
        else => {},
    };
    try testing.expectEqualStrings(raw, action.?.pane_output.data);
    try testing.expectEqualStrings(pane, &action.?.pane_output.pane_id);
}

test "viewer treats SESSION_END as exit" {
    var viewer = Viewer.init(testing.allocator);
    defer viewer.deinit();
    const action = try viewer.process(testing.allocator, .{
        .header = .session_end,
        .payload = &.{},
    });
    try testing.expectEqual(Action.exit, action.?);
}

test "viewer flags invalid length" {
    var viewer = Viewer.init(testing.allocator);
    defer viewer.deinit();
    const action = try viewer.process(testing.allocator, .{
        .header = .insert_keys,
        .payload = &.{},
        .invalid_length = true,
    });
    try testing.expectEqual(Action.invalid_length, action.?);
}
