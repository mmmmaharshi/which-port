//! The one seam: from a port to every Occupier of a Listening socket on it.
//!
//! Everything above this file — argument parsing, table layout, exit codes — is
//! platform independent and reaches the OS only through `lookup`.

const std = @import("std");
const builtin = @import("builtin");

/// One Occupier's claim on one Listening socket.
///
/// There is one of these per *socket*, not per process: an Occupier bound to
/// both IPv4 and IPv6 produces two rows. See CONTEXT.md.
pub const Occupier = struct {
    /// The holding process, or null when the OS would not name one. A null here
    /// is never an error either: the socket is Occupied either way, and the
    /// socket's own address still tells you what to go and look at.
    pid: ?u32,
    /// The socket's own bind address in full form, never collapsed to a
    /// wildcard: `0.0.0.0:8080` or `[::]:8080`.
    local_address: []const u8,
    /// Basename of the Occupier's image, e.g. `node.exe`, or `unresolved`.
    process_name: []const u8,
    /// Full image path, or null when the OS withholds it. A null here is never
    /// an error — see `path_note`.
    path: ?[]const u8,
    /// Why the process or path is unknown. Empty when both are known.
    identity_note: []const u8,
};

/// Stands in for a name the OS would not give us. Not an error value — see
/// CONTEXT.md, "Withheld identity".
pub const unresolved = "-";

/// An Occupier we can name by socket but not by process.
///
/// Shared by every platform: withholding metadata is not platform specific, and
/// keeping one copy is what stops the contract in CONTEXT.md from being amended
/// in two places and only one of them.
pub fn withheld(
    gpa: std.mem.Allocator,
    local_address: []const u8,
    pid: ?u32,
    note: []const u8,
) std.mem.Allocator.Error!Occupier {
    return .{
        .pid = pid,
        .local_address = try gpa.dupe(u8, local_address),
        .process_name = unresolved,
        .path = null,
        .identity_note = note,
    };
}

/// One Occupier whose identity the OS named in full.
///
/// The counterpart to `withheld`, and beside it for the same reason: the two
/// halves of the Occupier contract are one contract, not one copy per platform.
/// `path` is borrowed and copied, so an adapter that had to allocate in order to
/// resolve it frees its own and hands over a slice it does not own.
pub fn named(
    gpa: std.mem.Allocator,
    local_address: []const u8,
    pid: u32,
    path: []const u8,
) std.mem.Allocator.Error!Occupier {
    return .{
        .pid = pid,
        .local_address = try gpa.dupe(u8, local_address),
        .process_name = try gpa.dupe(u8, std.fs.path.basename(path)),
        .path = try gpa.dupe(u8, path),
        .identity_note = "",
    };
}

/// Deterministic order: by pid, then by address, so a dual-stack pair lands
/// IPv4 first and repeated runs print an identical table.
pub fn lessThan(_: void, a: Occupier, b: Occupier) bool {
    if (a.pid != b.pid) return (a.pid orelse 0) < (b.pid orelse 0);
    return std.mem.order(u8, a.local_address, b.local_address) == .lt;
}

const impl = switch (builtin.os.tag) {
    .windows => @import("win.zig"),
    .linux => @import("lin.zig"),
    .macos => @compileError("macOS lookup arrives with the lsof ticket"),
    else => @compileError("which-port supports Windows, Linux and macOS"),
};

pub const LookupError = impl.LookupError || std.mem.Allocator.Error;

/// Every Occupier holding a Listening socket on `port`, one entry per socket,
/// ordered by pid so that repeated runs print an identical table.
///
/// Allocates the returned slice and every string in it from `gpa`.
pub fn lookup(io: std.Io, gpa: std.mem.Allocator, port: u16) LookupError![]Occupier {
    const rows = try impl.lookup(io, gpa, port);
    // Row order is part of what a caller is promised, so the seam applies it.
    // Leaving it to each adapter is how a new platform ships rows in kernel
    // order and the promise quietly stops being true.
    std.sort.heap(Occupier, rows, {}, lessThan);
    return rows;
}

const testing = std.testing;

// One Occupier per socket, and the name is the basename while the Path is the
// whole thing: CONTEXT.md avoids "executable" precisely because the name is not
// the path, and user story 4 depends on telling a real install from a shim.
test "named derives the process name from the path's basename" {
    // basename follows the separator of the platform the binary was built for,
    // and an adapter only ever resolves a native path, so the drive-letter form
    // is the case worth pinning.
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const gpa = testing.allocator;
    const o = try named(gpa, "0.0.0.0:53", 53, "C:\\Program Files\\nodejs\\node.exe");
    defer gpa.free(o.local_address);
    defer gpa.free(o.process_name);
    defer gpa.free(o.path.?);

    try testing.expectEqual(@as(?u32, 53), o.pid);
    try testing.expectEqualStrings("node.exe", o.process_name);
    try testing.expectEqualStrings("C:\\Program Files\\nodejs\\node.exe", o.path.?);
    try testing.expectEqualStrings("", o.identity_note);
}

// Row order is a promise the seam makes rather than an accident of whichever
// adapter produced the rows. A dual-stack pair is one process, so the two rows
// are separated by address alone and the IPv4 one lands first.
//
// This passed on the first run: lessThan already existed and already behaved
// this way, so this is characterisation of untested code, not a red-green cycle.
test "a dual-stack pair sorts IPv4 first" {
    const v4 = Occupier{ .pid = 53, .local_address = "0.0.0.0:53", .process_name = "x", .path = null, .identity_note = "" };
    const v6 = Occupier{ .pid = 53, .local_address = "[::]:53", .process_name = "x", .path = null, .identity_note = "" };
    try testing.expect(lessThan({}, v4, v6));
    try testing.expect(!lessThan({}, v6, v4));
}
