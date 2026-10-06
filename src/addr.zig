//! Address formatting, shared by every platform so that a Local address looks
//! the same wherever it came from. Always the full form — a wildcard would
//! discard the one fact that makes a dual-stack pair legible. See CONTEXT.md.
//!
//! This is a thin shim over `std.Io.net.IpAddress.format`, which already does
//! the zero-run compression and the bracketing. It took the first version of
//! this file to reimplement all of it; std renders IPv4-mapped addresses as
//! `::ffff:127.0.0.1`, which RFC 5952 section 5 recommends and the hand-rolled
//! version did not.
const std = @import("std");

const IpAddress = std.Io.net.IpAddress;

/// The longest possible Local address: `[ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]:65535`,
/// which is 47 bytes -- one bracket, 32 hex digits, 7 inner colons, one closing
/// bracket, one colon, and a five-digit port.
///
/// Public so a caller can size its buffer from the module that owns the bound
/// rather than hardcode a number and trust a comment. `var buf: [addr.maxLen]u8`
/// makes a too-small buffer a compile error here, instead of an unreachable
/// error branch at the call site that silently depends on the arithmetic being
/// right in three different files.
///
/// This said 46 until the test below computed the real figure. The callers all
/// used 64, so the wrong bound had never mattered.
pub const maxLen = 47;

/// A 4-byte address as `/proc` and the Windows table each hand it over: a 32-bit
/// word in network byte order, so the first octet is the *last* byte here.
pub fn addr4(buf: []u8, raw: u32, port: u16) ![]u8 {
    const o = @byteSwap(raw);
    return writeIp(buf, .{ .ip4 = .{ .bytes = .{ @truncate(o >> 24), @truncate(o >> 16), @truncate(o >> 8), @truncate(o) }, .port = port } });
}

/// A 16-byte address in memory order.
pub fn addr6(buf: []u8, raw: [16]u8, port: u16) ![]u8 {
    return writeIp(buf, .{ .ip6 = .{ .bytes = raw, .port = port } });
}

fn writeIp(buf: []u8, ip: IpAddress) ![]u8 {
    if (buf.len < maxLen) return error.NoSpaceLeft;
    var w = std.Io.Writer.fixed(buf);
    try ip.format(&w);
    return w.buffered();
}

const testing = std.testing;

test "IPv4 always prints in full form, never a wildcard" {
    var buf: [maxLen]u8 = undefined;
    // 0.0.0.0, which a wildcard-collapsing tool would print as `*`.
    try testing.expectEqualStrings("0.0.0.0:8080", try addr4(&buf, 0x00000000, 8080));
    try testing.expectEqualStrings("127.0.0.1:35765", try addr4(&buf, 0x0100007F, 35765));
}

test "IPv6 brackets the address and compresses only runs of two or more" {
    var buf: [maxLen]u8 = undefined;
    try testing.expectEqualStrings("[::]:8080", try addr6(&buf, @splat(0), 8080));

    var loopback: [16]u8 = @splat(0);
    loopback[15] = 1;
    try testing.expectEqualStrings("[::1]:22", try addr6(&buf, loopback, 22));

    // ::ffff:127.0.0.1 — a single zero group is not compressed away, and RFC 5952
    // section 5 asks for the dotted quad rather than hex here.
    var mapped: [16]u8 = @splat(0);
    mapped[10] = 0xff;
    mapped[11] = 0xff;
    mapped[12] = 0x7f;
    mapped[15] = 0x01;
    try testing.expectEqualStrings("[::ffff:127.0.0.1]:80", try addr6(&buf, mapped, 80));
}

test "a run of one zero group is left alone" {
    var buf: [maxLen]u8 = undefined;
    // 2001:0:db8:1:1:1:1:1 — group 1 is zero and nothing follows it, so there is
    // no run to compress and the zero has to survive.
    const raw = [16]u8{
        0x20, 0x01, // 2001
        0x00, 0x00, // 0
        0x0d, 0xb8, // db8
        0x00, 0x01, // 1
        0x00, 0x01, // 1
        0x00, 0x01, // 1
        0x00, 0x01, // 1
        0x00, 0x01, // 1
    };
    try testing.expectEqualStrings("[2001:0:db8:1:1:1:1:1]:443", try addr6(&buf, raw, 443));
}

// maxLen is what every caller sizes its buffer from, and a caller that sizes it
// one byte short gets an error it cannot see coming. So the bound is checked
// against the longest address that can actually be produced: every group
// non-zero, so nothing compresses, at the highest port.
test "maxLen holds the longest address that needs no compression" {
    var buf: [maxLen]u8 = undefined;
    const raw = [16]u8{
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    };
    const out = try addr6(&buf, raw, 65535);
    try testing.expectEqualStrings("[ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]:65535", out);
    try testing.expectEqual(maxLen, out.len);
}
