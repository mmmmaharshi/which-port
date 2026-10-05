//! Address formatting, shared by every platform so that a Local address looks
//! the same wherever it came from. Always the full form — a wildcard would
//! discard the one fact that makes a dual-stack pair legible. See CONTEXT.md.
const std = @import("std");

const format = std.fmt.bufPrint;

/// A 4-byte address as `/proc` and the Windows table each hand it over: a 32-bit
/// word in network byte order, so the first octet is the *last* byte here and the
/// `@byteSwap` below puts them back in reading order.
pub fn addr4(buf: []u8, raw: u32, port: u16) ![]u8 {
    const addr = @byteSwap(raw);
    return format(buf, "{d}.{d}.{d}.{d}:{d}", .{
        @as(u8, @truncate(addr >> 24)),
        @as(u8, @truncate(addr >> 16)),
        @as(u8, @truncate(addr >> 8)),
        @as(u8, @truncate(addr)),
        port,
    });
}

/// A 16-byte address in memory order.
pub fn addr6(buf: []u8, raw: [16]u8, port: u16) ![]u8 {
    var groups: [8]u16 = undefined;
    for (&groups, 0..) |*g, i| g.* = @as(u16, @byteSwap(@as(*align(1) const u16, @ptrCast(&raw[i * 2])).*));

    var best_start: usize = 0;
    var best_len: usize = 0;
    var run_start: usize = 0;
    var run_len: usize = 0;
    for (groups, 0..) |g, i| {
        if (g == 0) {
            if (run_len == 0) run_start = i;
            run_len += 1;
            if (run_len > best_len) {
                best_len = run_len;
                best_start = run_start;
            }
        } else run_len = 0;
    }
    if (best_len < 2) best_len = 0; // `::` must stand for at least two groups

    var end: usize = 1; // buf[0] = '['
    buf[0] = '[';
    var i: usize = 0;
    var wrote_any = false;
    while (i < groups.len) : (i += 1) {
        if (best_len != 0 and i == best_start) {
            if (i == 0) {
                buf[end] = ':';
                end += 1;
            }
            buf[end] = ':';
            end += 1;
            i += best_len - 1;
            continue;
        }
        if (wrote_any) {
            buf[end] = ':';
            end += 1;
        }
        const hex = try format(buf[end..], "{x}", .{groups[i]});
        end += hex.len;
        wrote_any = true;
    }
    buf[end] = ']';
    end += 1;
    const tail = try format(buf[end..], ":{d}", .{port});
    return buf[0 .. end + tail.len];
}

const testing = std.testing;

test "IPv4 always prints in full form, never a wildcard" {
    var buf: [64]u8 = undefined;
    // 0.0.0.0, which a wildcard-collapsing tool would print as `*`.
    try testing.expectEqualStrings("0.0.0.0:8080", try addr4(&buf, 0x00000000, 8080));
    try testing.expectEqualStrings("127.0.0.1:35765", try addr4(&buf, 0x0100007F, 35765));
}

test "IPv6 brackets the address and compresses only runs of two or more" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("[::]:8080", try addr6(&buf, @splat(0), 8080));

    var loopback: [16]u8 = @splat(0);
    loopback[15] = 1;
    try testing.expectEqualStrings("[::1]:22", try addr6(&buf, loopback, 22));

    // ::ffff:127.0.0.1 — a single zero group must not be compressed away.
    var mapped: [16]u8 = @splat(0);
    mapped[10] = 0xff;
    mapped[11] = 0xff;
    mapped[12] = 0x7f;
    mapped[15] = 0x01;
    try testing.expectEqualStrings("[::ffff:7f00:1]:80", try addr6(&buf, mapped, 80));
}
