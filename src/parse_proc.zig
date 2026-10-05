//! Parses the Linux proc network tables. Deliberately free of any OS dependency
//! so it compiles, and is tested, on any machine — the fixture beside it came from
//! a real kernel, not from this file's author's imagination.
//!
//! The one column that matters more than the others is the inode: it is how the
//! kernel lets us find the process holding a socket. Get the columns wrong and
//! this reports an Occupied port as Free, which is the quietest failure this tool
//! can make. See CONTEXT.md.

const std = @import("std");

pub const ParseError = error{ Unreadable, OutOfMemory };

/// `st` is the hex TCP state. Only `0A` is a Listening socket.
pub const listen_hex = "0A";

pub const Socket = struct {
    /// Four bytes as the kernel prints them, for the shared formatter.
    raw4: u32,
    /// Sixteen bytes as the kernel prints them, for the shared formatter.
    raw6: [16]u8,
    port: u16,
    inode: u64,
    family6: bool,
};

/// `text` is one whole proc table, verbatim. Returns every Listening socket in
/// it, IPv4 and IPv6 rows alike, in the order the kernel printed them.
pub fn parse(gpa: std.mem.Allocator, text: []const u8, out: *std.ArrayList(Socket)) ParseError!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    _ = lines.next(); // header
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try parseLine(gpa, line, out);
    }
}

fn parseLine(gpa: std.mem.Allocator, line: []const u8, out: *std.ArrayList(Socket)) ParseError!void {
    var fields = std.mem.tokenizeAny(u8, line, " \t");
    const sl = fields.next() orelse return;

    // Column 0 is `sl:` ("0:"). Any other shape means the layout moved under us,
    // and guessing is how a Live port gets reported as Free.
if (sl.len < 2 or sl[sl.len - 1] != ':') return error.Unreadable;
    const local_field = fields.next() orelse return error.Unreadable;
    if (fields.next() == null) return error.Unreadable; // rem_address

    const st = fields.next() orelse return error.Unreadable;
    if (!std.mem.eql(u8, st, listen_hex)) return;

// Between `st` and `inode` sit five whitespace-separated tokens, not eight:
    // the kernel prints tx_queue:rx_queue and tr:tm->when as single
    // colon-joined tokens even though they are four header columns. Counting
    // header columns instead of tokens lands on the wrong field and reads a
    // Live port as Free.
    //   tx_queue:rx_queue  tr:tm->when  retrnsmt  uid  timeout
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        _ = fields.next() orelse return error.Unreadable;
    }
    const inode_text = fields.next() orelse return error.Unreadable;
    const inode = std.fmt.parseInt(u64, inode_text, 10) catch return error.Unreadable;

// The address is `HEX:HEXPORT`. Read it from the token we already have: the
    // line also begins `0:`, so scanning for the first colon finds the wrong one.
    const sep = std.mem.indexOfScalar(u8, local_field, ':') orelse return error.Unreadable;
    const addr_hex = local_field[0..sep];
    const port = std.fmt.parseInt(u16, local_field[sep + 1 ..], 16) catch return error.Unreadable;

    const family6 = addr_hex.len == 32;
    if (!family6 and addr_hex.len != 8) return error.Unreadable;

    var socket = Socket{
        .raw4 = 0,
        .raw6 = if (family6) try rawSix(addr_hex) else @splat(0),
        .port = port,
        .inode = inode,
        .family6 = family6,
    };
    // IPv4 arrives as one reversed 32-bit word, which is exactly what the shared
    // four-byte formatter takes.
    if (!family6) socket.raw4 = std.fmt.parseInt(u32, addr_hex, 16) catch return error.Unreadable;
    try out.append(gpa, socket);
}

/// Sixteen hex characters in kernel order straight into memory order.
fn rawSix(hex: []const u8) ParseError![16]u8 {
    var out: [16]u8 = undefined;
    for (&out, 0..) |*b, i| {
        const pair = hex[i * 2 ..][0..2];
        b.* = std.fmt.parseInt(u8, pair, 16) catch return error.Unreadable;
    }
    return out;
}

// ---------------------------------------------------------------- fixtures

const testing = std.testing;

/// Captured verbatim from a real Linux kernel, with the listener this test binds
/// and a mix of other states. Committed, never hand-edited.
const fixture4 = @embedFile("fixture_tcp.txt");
const fixture6 = @embedFile("fixture_tcp6.txt");

test "Listening sockets are found and other states are not" {
    var out: std.ArrayList(Socket) = .empty;
    const gpa = testing.allocator;
    defer out.deinit(gpa);
    try parse(gpa, fixture4, &out);

    // This fixture provably contains non-Listening rows, or the test proves nothing.
    var saw_non_listen = false;
    var lines = std.mem.splitScalar(u8, fixture4, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        var f = std.mem.tokenizeAny(u8, line, " \t");
        const sl = f.next() orelse continue;
        if (sl.len < 2) continue;
        _ = f.next();
        _ = f.next();
        const st = f.next() orelse continue;
        if (!std.mem.eql(u8, st, listen_hex)) saw_non_listen = true;
    }
    try testing.expect(saw_non_listen);

    for (out.items) |s| try testing.expect(s.inode != 0);
}

test "the IPv6 table parses and yields 16-byte addresses" {
    var out: std.ArrayList(Socket) = .empty;
    const gpa = testing.allocator;
    defer out.deinit(gpa);
    try parse(gpa, fixture6, &out);
    for (out.items) |s| try testing.expect(s.family6);
}

test "a port nobody is listening on yields nothing" {
    var out: std.ArrayList(Socket) = .empty;
    const gpa = testing.allocator;
    defer out.deinit(gpa);
    // A single ESTABLISHED row: not a Listening socket, so not an Occupier.
    const established = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n   3: 28D41BAC:8208 C9513617:0050 06 00000000:00000000 00:00000000 00000000     0        0 777 1 0 100 0 0 10 0\n";
    try parse(gpa, established, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "a column that moved is reported, never guessed" {
    var out: std.ArrayList(Socket) = .empty;
    const gpa = testing.allocator;
    defer out.deinit(gpa);
// `sl` is not `N:`. Reading this as if it were would invent an Occupier.
    const head = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n";
    try testing.expectError(error.Unreadable, parse(gpa, head ++ "   x 0100007F:1F90 00000000:0000 0A 0 0 0 0 0 0 0 42\n", &out));
    // Truncated before the inode column.
    try testing.expectError(error.Unreadable, parse(gpa, head ++ "   0: 0100007F:1F90 00000000:0000 0A 0 0\n", &out));
}


