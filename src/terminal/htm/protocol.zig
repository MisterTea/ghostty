//! HTM (Headless Terminal Multiplexer) wire protocol.
//!
//! Framing matches Eternal Terminal / hyper-htm:
//! `[1-byte header][8-char base64(int32 LE length)][payload]`
//! except `SESSION_END` (`D`) which is a single byte.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const UUID_LENGTH = 36;
pub const Uuid = [UUID_LENGTH]u8;

pub const init_seq = "\x1b[###q";
pub const exit_seq = "\x1b[$$$q";

pub const Header = enum(u8) {
    insert_keys = '1',
    init_state = '2',
    client_close_pane = '3',
    append_to_pane = '4',
    new_tab = '5',
    server_close_pane = '8',
    new_split = '9',
    resize_pane = 'A',
    debug_log = 'B',
    insert_debug_keys = 'C',
    session_end = 'D',
    _,
};

pub const Packet = struct {
    header: Header,
    payload: []const u8,
    /// True when the length field decoded to a negative int32.
    invalid_length: bool = false,
};

pub fn encodeLength(length: i32) [8]u8 {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(i32, &bytes, length, .little);
    var out: [8]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &bytes);
    return out;
}

pub fn decodeLength(b64: []const u8) error{InvalidLength}!i32 {
    if (b64.len != 8) return error.InvalidLength;
    var bytes: [4]u8 = undefined;
    std.base64.standard.Decoder.decode(&bytes, b64) catch return error.InvalidLength;
    return std.mem.readInt(i32, &bytes, .little);
}

pub fn longestInitPrefix(data: []const u8) usize {
    const needle = init_seq;
    const max = @min(data.len, needle.len - 1);
    var n = max;
    while (n > 0) : (n -= 1) {
        if (std.mem.startsWith(u8, needle, data[data.len - n ..])) return n;
    }
    return 0;
}

pub const ConsumeInit = struct {
    matched: bool,
    prefix: []const u8,
    remainder: []const u8,
    pending: []const u8,
};

/// Detect HTM init in a (possibly chunked) payload. `combined` must be
/// `pending ++ payload`. Returned slices point into `combined`.
pub fn consumeInitPayload(combined: []const u8) ConsumeInit {
    if (std.mem.indexOf(u8, combined, init_seq)) |init_at| {
        return .{
            .matched = true,
            .prefix = combined[0..init_at],
            .remainder = combined[init_at + init_seq.len ..],
            .pending = &.{},
        };
    }
    const hold = longestInitPrefix(combined);
    if (hold > 0) {
        return .{
            .matched = false,
            .prefix = combined[0 .. combined.len - hold],
            .remainder = &.{},
            .pending = combined[combined.len - hold ..],
        };
    }
    return .{
        .matched = false,
        .prefix = combined,
        .remainder = &.{},
        .pending = &.{},
    };
}

pub const ParseResult = struct {
    packets: []Packet,
    rest: []const u8,
};

/// Parse complete HTM packets from `buffer`. Packet payloads are slices of
/// `buffer`. `SESSION_END` is recognized without a length field and stops
/// parsing. The caller owns `packets` (allocated with `alloc`).
pub fn parsePackets(alloc: Allocator, buffer: []const u8) Allocator.Error!ParseResult {
    var packets: std.ArrayList(Packet) = .empty;
    errdefer packets.deinit(alloc);

    var offset: usize = 0;
    while (offset < buffer.len) {
        const header: Header = @enumFromInt(buffer[offset]);
        if (header == .session_end) {
            try packets.append(alloc, .{
                .header = header,
                .payload = &.{},
            });
            offset += 1;
            break;
        }
        if (buffer.len - offset < 9) break;
        const length = decodeLength(buffer[offset + 1 .. offset + 9]) catch {
            try packets.append(alloc, .{
                .header = header,
                .payload = &.{},
                .invalid_length = true,
            });
            break;
        };
        if (length < 0) {
            try packets.append(alloc, .{
                .header = header,
                .payload = &.{},
                .invalid_length = true,
            });
            break;
        }
        const ulen: usize = @intCast(length);
        if (buffer.len - offset - 9 < ulen) break;
        try packets.append(alloc, .{
            .header = header,
            .payload = buffer[offset + 9 .. offset + 9 + ulen],
        });
        offset += 9 + ulen;
    }

    return .{
        .packets = try packets.toOwnedSlice(alloc),
        .rest = buffer[offset..],
    };
}

/// Parse a single complete packet. `consumed` is 0 when more bytes are needed.
pub fn parseOne(buffer: []const u8) struct { packet: ?Packet, consumed: usize } {
    if (buffer.len == 0) return .{ .packet = null, .consumed = 0 };
    const header: Header = @enumFromInt(buffer[0]);
    if (header == .session_end) {
        return .{
            .packet = .{ .header = header, .payload = &.{} },
            .consumed = 1,
        };
    }
    if (buffer.len < 9) return .{ .packet = null, .consumed = 0 };
    const length = decodeLength(buffer[1..9]) catch {
        return .{
            .packet = .{
                .header = header,
                .payload = &.{},
                .invalid_length = true,
            },
            .consumed = 9,
        };
    };
    if (length < 0) {
        return .{
            .packet = .{
                .header = header,
                .payload = &.{},
                .invalid_length = true,
            },
            .consumed = 9,
        };
    }
    const ulen: usize = @intCast(length);
    if (buffer.len - 9 < ulen) return .{ .packet = null, .consumed = 0 };
    return .{
        .packet = .{
            .header = header,
            .payload = buffer[9 .. 9 + ulen],
        },
        .consumed = 9 + ulen,
    };
}

pub fn encodePacket(alloc: Allocator, header: Header, payload: []const u8) Allocator.Error![]u8 {
    if (header == .session_end) {
        const out = try alloc.alloc(u8, 1);
        out[0] = @intFromEnum(Header.session_end);
        return out;
    }
    const len_field = encodeLength(@intCast(payload.len));
    const out = try alloc.alloc(u8, 1 + 8 + payload.len);
    out[0] = @intFromEnum(header);
    @memcpy(out[1..9], &len_field);
    @memcpy(out[9..], payload);
    return out;
}

pub fn encodeInsertKeys(alloc: Allocator, pane_id: Uuid, keys: []const u8) Allocator.Error![]u8 {
    const b64_len = std.base64.standard.Encoder.calcSize(keys.len);
    const payload_len = UUID_LENGTH + b64_len;
    const len_field = encodeLength(@intCast(payload_len));
    const out = try alloc.alloc(u8, 1 + 8 + payload_len);
    out[0] = @intFromEnum(Header.insert_keys);
    @memcpy(out[1..9], &len_field);
    @memcpy(out[9 .. 9 + UUID_LENGTH], &pane_id);
    _ = std.base64.standard.Encoder.encode(out[9 + UUID_LENGTH ..], keys);
    return out;
}

pub fn encodeInsertDebugKeys(alloc: Allocator, keys: []const u8) Allocator.Error![]u8 {
    return encodePacket(alloc, .insert_debug_keys, keys);
}

pub fn encodeNewTab(alloc: Allocator, tab_id: Uuid, pane_id: Uuid) Allocator.Error![]u8 {
    var payload: [UUID_LENGTH * 2]u8 = undefined;
    @memcpy(payload[0..UUID_LENGTH], &tab_id);
    @memcpy(payload[UUID_LENGTH..], &pane_id);
    return encodePacket(alloc, .new_tab, &payload);
}

pub fn encodeNewSplit(
    alloc: Allocator,
    source_id: Uuid,
    new_id: Uuid,
    vertical: bool,
) Allocator.Error![]u8 {
    var payload: [UUID_LENGTH * 2 + 1]u8 = undefined;
    @memcpy(payload[0..UUID_LENGTH], &source_id);
    @memcpy(payload[UUID_LENGTH .. UUID_LENGTH * 2], &new_id);
    payload[UUID_LENGTH * 2] = if (vertical) '1' else '0';
    return encodePacket(alloc, .new_split, &payload);
}

pub fn encodeClientClosePane(alloc: Allocator, pane_id: Uuid) Allocator.Error![]u8 {
    return encodePacket(alloc, .client_close_pane, &pane_id);
}

pub fn encodeResizePane(
    alloc: Allocator,
    cols: i32,
    rows: i32,
    pane_id: Uuid,
) Allocator.Error![]u8 {
    const cols_b64 = encodeLength(cols);
    const rows_b64 = encodeLength(rows);
    var payload: [8 + 8 + UUID_LENGTH]u8 = undefined;
    @memcpy(payload[0..8], &cols_b64);
    @memcpy(payload[8..16], &rows_b64);
    @memcpy(payload[16..], &pane_id);
    return encodePacket(alloc, .resize_pane, &payload);
}

pub fn parseUuid(payload: []const u8) ?Uuid {
    if (payload.len < UUID_LENGTH) return null;
    var id: Uuid = undefined;
    @memcpy(&id, payload[0..UUID_LENGTH]);
    return id;
}

fn fillRandom(buf: []u8) void {
    if (buf.len == 0) return;
    // Zig 0.16 removed std.crypto.random; match TinyIo's CSPRNG sources.
    if (builtin.link_libc and @TypeOf(std.posix.system.arc4random_buf) != void) {
        std.posix.system.arc4random_buf(buf.ptr, buf.len);
        return;
    }
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var i: usize = 0;
        while (i < buf.len) {
            const rc = linux.getrandom(buf[i..].ptr, buf.len - i, 0);
            switch (linux.errno(rc)) {
                .SUCCESS => i += rc,
                .INTR => continue,
                else => @panic("getrandom failed"),
            }
        }
        return;
    }
    @panic("no CSPRNG available");
}

pub fn generateUuid() Uuid {
    var bytes: [16]u8 = undefined;
    fillRandom(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const hex = "0123456789abcdef";
    var out: Uuid = undefined;
    var i: usize = 0;
    var o: usize = 0;
    const groups = [_]usize{ 4, 2, 2, 2, 6 };
    for (groups, 0..) |g, gi| {
        if (gi > 0) {
            out[o] = '-';
            o += 1;
        }
        var n: usize = 0;
        while (n < g) : (n += 1) {
            const b = bytes[i];
            i += 1;
            out[o] = hex[b >> 4];
            out[o + 1] = hex[b & 0x0f];
            o += 2;
        }
    }
    return out;
}

pub fn decodeBase64(alloc: Allocator, encoded: []const u8) (Allocator.Error || error{InvalidBase64})![]u8 {
    const Decoder = std.base64.standard.Decoder;
    const n = Decoder.calcSizeForSlice(encoded) catch return error.InvalidBase64;
    const out = try alloc.alloc(u8, n);
    errdefer alloc.free(out);
    Decoder.decode(out, encoded) catch {
        alloc.free(out);
        return error.InvalidBase64;
    };
    return out;
}

test "encodeLength / decodeLength round-trips common payload sizes" {
    for ([_]i32{ 0, 1, 36, 72, 73, 128, 1024 }) |n| {
        try testing.expectEqual(n, try decodeLength(&encodeLength(n)));
    }
}

test "encodeLength preserves negative int32 values used as invalid lengths" {
    try testing.expectEqual(@as(i32, -1), try decodeLength(&encodeLength(-1)));
}

test "longestInitPrefix returns 0 when there is no prefix" {
    try testing.expectEqual(@as(usize, 0), longestInitPrefix("hello"));
    try testing.expectEqual(@as(usize, 0), longestInitPrefix(""));
}

test "longestInitPrefix holds a split ESC[###q prefix" {
    try testing.expectEqual(@as(usize, 1), longestInitPrefix("\x1b"));
    try testing.expectEqual(@as(usize, 2), longestInitPrefix("\x1b["));
    try testing.expectEqual(@as(usize, 4), longestInitPrefix("\x1b[##"));
    try testing.expectEqual(@as(usize, 5), longestInitPrefix("\x1b[###"));
}

test "longestInitPrefix does not treat a full match as a hold-back prefix" {
    try testing.expectEqual(@as(usize, 0), longestInitPrefix(init_seq));
}

test "consumeInitPayload matches when the sequence arrives in one chunk" {
    const data = "pre" ++ init_seq ++ "rest";
    const result = consumeInitPayload(data);
    try testing.expect(result.matched);
    try testing.expectEqualStrings("pre", result.prefix);
    try testing.expectEqualStrings("rest", result.remainder);
    try testing.expectEqual(@as(usize, 0), result.pending.len);
}

test "consumeInitPayload holds a trailing partial sequence across chunks" {
    const first = consumeInitPayload("abc\x1b[");
    try testing.expect(!first.matched);
    try testing.expectEqualStrings("abc", first.prefix);
    try testing.expectEqualStrings("\x1b[", first.pending);

    var combined_buf: [16]u8 = undefined;
    const combined = combined_buf[0 .. first.pending.len + "###qINIT".len];
    @memcpy(combined[0..first.pending.len], first.pending);
    @memcpy(combined[first.pending.len..], "###qINIT");
    const second = consumeInitPayload(combined);
    try testing.expect(second.matched);
    try testing.expectEqualStrings("", second.prefix);
    try testing.expectEqualStrings("INIT", second.remainder);
}

test "consumeInitPayload passes through data with no init sequence" {
    const result = consumeInitPayload("plain output");
    try testing.expect(!result.matched);
    try testing.expectEqualStrings("plain output", result.prefix);
    try testing.expectEqual(@as(usize, 0), result.pending.len);
}

test "parsePackets parses a complete INIT_STATE packet" {
    const payload = "{\"panes\":{}}";
    const len_field = encodeLength(@intCast(payload.len));
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(testing.allocator);
    try buffer.append(testing.allocator, @intFromEnum(Header.init_state));
    try buffer.appendSlice(testing.allocator, &len_field);
    try buffer.appendSlice(testing.allocator, payload);

    const parsed = try parsePackets(testing.allocator, buffer.items);
    defer testing.allocator.free(parsed.packets);
    try testing.expectEqual(@as(usize, 1), parsed.packets.len);
    try testing.expectEqual(Header.init_state, parsed.packets[0].header);
    try testing.expectEqualStrings(payload, parsed.packets[0].payload);
    try testing.expectEqual(@as(usize, 0), parsed.rest.len);
}

test "parsePackets recognizes a 1-byte SESSION_END without waiting for a length" {
    const parsed = try parsePackets(testing.allocator, "D");
    defer testing.allocator.free(parsed.packets);
    try testing.expectEqual(@as(usize, 1), parsed.packets.len);
    try testing.expectEqual(Header.session_end, parsed.packets[0].header);
    try testing.expectEqual(@as(usize, 0), parsed.packets[0].payload.len);
    try testing.expectEqual(@as(usize, 0), parsed.rest.len);
}

test "parsePackets holds a partial packet until the payload arrives" {
    const payload = "abc";
    const len_field = encodeLength(@intCast(payload.len));
    var full: std.ArrayList(u8) = .empty;
    defer full.deinit(testing.allocator);
    try full.append(testing.allocator, @intFromEnum(Header.insert_keys));
    try full.appendSlice(testing.allocator, &len_field);
    try full.appendSlice(testing.allocator, payload);

    const partial = try parsePackets(testing.allocator, full.items[0..5]);
    defer testing.allocator.free(partial.packets);
    try testing.expectEqual(@as(usize, 0), partial.packets.len);
    try testing.expectEqualStrings(full.items[0..5], partial.rest);

    const complete = try parsePackets(testing.allocator, full.items);
    defer testing.allocator.free(complete.packets);
    try testing.expectEqual(@as(usize, 1), complete.packets.len);
    try testing.expectEqualStrings(payload, complete.packets[0].payload);
}

test "parsePackets surfaces an invalid negative length" {
    const len_field = encodeLength(-3);
    var buffer: [9]u8 = undefined;
    buffer[0] = @intFromEnum(Header.insert_keys);
    @memcpy(buffer[1..], &len_field);
    const parsed = try parsePackets(testing.allocator, &buffer);
    defer testing.allocator.free(parsed.packets);
    try testing.expectEqual(@as(usize, 1), parsed.packets.len);
    try testing.expect(parsed.packets[0].invalid_length);
}

test "parsePackets stops after SESSION_END even if more bytes follow" {
    const parsed = try parsePackets(testing.allocator, "D1junk");
    defer testing.allocator.free(parsed.packets);
    try testing.expectEqual(@as(usize, 1), parsed.packets.len);
    try testing.expectEqual(Header.session_end, parsed.packets[0].header);
    try testing.expect(std.mem.startsWith(u8, parsed.rest, "1"));
}

test "parseOne returns a complete packet and consumed byte count" {
    const payload = "xyz";
    const packet_bytes = try encodePacket(testing.allocator, .debug_log, payload);
    defer testing.allocator.free(packet_bytes);
    const one = parseOne(packet_bytes);
    try testing.expect(one.packet != null);
    try testing.expectEqual(Header.debug_log, one.packet.?.header);
    try testing.expectEqualStrings(payload, one.packet.?.payload);
    try testing.expectEqual(packet_bytes.len, one.consumed);
}

test "parseOne waits for a full payload" {
    const packet_bytes = try encodePacket(testing.allocator, .debug_log, "abcd");
    defer testing.allocator.free(packet_bytes);
    const one = parseOne(packet_bytes[0 .. packet_bytes.len - 1]);
    try testing.expect(one.packet == null);
    try testing.expectEqual(@as(usize, 0), one.consumed);
}

test "encodeInsertKeys frames pane UUID plus base64 key bytes" {
    const pane = parseUuid("11111111-2222-3333-4444-555555555555").?;
    const packet = try encodeInsertKeys(testing.allocator, pane, "ab");
    defer testing.allocator.free(packet);
    const one = parseOne(packet);
    try testing.expectEqual(Header.insert_keys, one.packet.?.header);
    try testing.expectEqualStrings("11111111-2222-3333-4444-555555555555", one.packet.?.payload[0..UUID_LENGTH]);
    const decoded = try decodeBase64(testing.allocator, one.packet.?.payload[UUID_LENGTH..]);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings("ab", decoded);
}
