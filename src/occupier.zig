//! The Occupier contract: the struct, the two ways an Occupier can be named, and
//! the row order. No platform here, deliberately.
//!
//! This used to be the top half of lookup.zig, which put it behind that file's
//! `switch (builtin.os.tag)`. Every adapter therefore imported the module that
//! dispatches to it -- lookup.zig -> win.zig -> lookup.zig -- and win.zig needed
//! two `@import` lines for one module because the vocabulary was reachable two
//! ways. Splitting them means an adapter depends on the contract and never on
//! its own dispatcher, and the contract in CONTEXT.md lives in a file no
//! `@compileError` can reach.

const std = @import("std");

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
    /// an error — see `identity_note`.
    path: ?[]const u8,
    /// The Command line the Occupier was started with, or null when the OS
    /// withholds it. Separate from `path` and not derived from it: `path` is the
    /// image on disk, this is what the caller passed, and a process that rewrites
    /// its own argument vector makes the two disagree. See CONTEXT.md.
    command_line: ?[]const u8,
    /// Why the Command line is missing. Empty when it is known.
    command_note: []const u8,
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
///
/// The Command line is null here rather than guessed: an Occupier whose process
/// the OS would not name has no command line to report either, and reporting
/// something would be inventing an identity. `command_note` is empty here too:
/// `identity_note` already explains every `-` in the row. See CONTEXT.md.
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
        .command_line = null,
        .command_note = "",
        .identity_note = note,
    };
}

/// One Occupier whose identity the OS named in full.
///
/// The counterpart to `withheld`, and beside it for the same reason: the two
/// halves of the Occupier contract are one contract, not one copy per platform.
/// `path` is borrowed and copied, so an adapter that had to allocate in order to
/// resolve it frees its own and hands over a slice it does not own.
///
/// `command_line` is optional for a reason the adapters cannot hide: Windows and
/// Linux disagree about which processes will give it up. An adapter that resolved
/// the Path but not the Command line passes null and still calls this, because a
/// named Occupier with a missing Command line is not a withheld Occupier — but
/// the reason its Command line is missing belongs in `command_note`, because a
/// Command line the OS withheld is metadata withheld: an occupier whose metadata
/// the OS refused. See CONTEXT.md, "Withheld identity".
pub fn named(
    gpa: std.mem.Allocator,
    local_address: []const u8,
    pid: u32,
    path: []const u8,
    command_line: ?[]const u8,
    command_note: []const u8,
) std.mem.Allocator.Error!Occupier {
    return .{
        .pid = pid,
        .local_address = try gpa.dupe(u8, local_address),
        .process_name = try gpa.dupe(u8, std.fs.path.basename(path)),
        .path = try gpa.dupe(u8, path),
        .command_line = if (command_line) |c| try gpa.dupe(u8, c) else null,
        .command_note = try gpa.dupe(u8, command_note),
        .identity_note = "",
    };
}

/// Deterministic order: by pid, then by address, so a dual-stack pair lands
/// IPv4 first and repeated runs print an identical table.
pub fn lessThan(_: void, a: Occupier, b: Occupier) bool {
    if (a.pid != b.pid) return (a.pid orelse 0) < (b.pid orelse 0);
    return std.mem.order(u8, a.local_address, b.local_address) == .lt;
}

const testing = std.testing;

// One Occupier per socket, and the name is the basename while the Path is the
// whole thing: CONTEXT.md avoids "executable" precisely because the name is not
// the path, and user story 4 depends on telling a real install from a shim.
test "named derives the process name from the path's basename" {
    // basename follows the separator of the platform the binary was built for,
    // and an adapter only ever resolves a native path, so the drive-letter form
    // is the case worth pinning.
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;

    const gpa = testing.allocator;
    const o = try named(gpa, "0.0.0.0:53", 53, "C:\\Program Files\\nodejs\\node.exe", "node server.js --port 53", "");
    defer gpa.free(o.local_address);
    defer gpa.free(o.process_name);
    defer gpa.free(o.path.?);
    defer gpa.free(o.command_line.?);

    try testing.expectEqual(@as(?u32, 53), o.pid);
    try testing.expectEqualStrings("node.exe", o.process_name);
    try testing.expectEqualStrings("C:\\Program Files\\nodejs\\node.exe", o.path.?);
    try testing.expectEqualStrings("node server.js --port 53", o.command_line.?);
    try testing.expectEqualStrings("", o.identity_note);
    try testing.expectEqualStrings("", o.command_note);
}

// The Command line is optional to `named` on purpose: an adapter can resolve the
// Path and still be refused the Command line, and that is a named Occupier with a
// missing field, not a withheld Occupier. Withheld must stay the other thing --
// no process, no Path, no Command line, and a note saying why.
test "a named Occupier can have no Command line, and withheld has none at all" {
    const gpa = testing.allocator;

    const without = try named(gpa, "0.0.0.0:80", 80, "/usr/bin/nginx", null, "could not read the command line (access denied, or it has exited)");
    defer gpa.free(without.local_address);
    defer gpa.free(without.process_name);
    defer gpa.free(without.path.?);
    defer gpa.free(without.command_note);
    try testing.expectEqual(@as(?[]const u8, null), without.command_line);
    try testing.expectEqualStrings("could not read the command line (access denied, or it has exited)", without.command_note);
    try testing.expectEqualStrings("", without.identity_note);

    const none = try withheld(gpa, "0.0.0.0:80", null, "access denied");
    defer gpa.free(none.local_address);
    try testing.expectEqual(@as(?[]const u8, null), none.path);
    try testing.expectEqual(@as(?[]const u8, null), none.command_line);
    try testing.expectEqual(unresolved, none.process_name);
    try testing.expectEqualStrings("access denied", none.identity_note);
}

// Row order is a promise the seam makes rather than an accident of whichever
// adapter produced the rows. A dual-stack pair is one process, so the two rows
// are separated by address alone and the IPv4 one lands first. The rows start in
// the wrong order, so a comparator that did nothing would fail this.
test "a dual-stack pair sorts IPv4 first" {
    var rows = [_]Occupier{
        .{ .pid = 53, .local_address = "[::]:53", .process_name = "x", .path = null, .command_line = null, .command_note = "", .identity_note = "" },
        .{ .pid = 53, .local_address = "0.0.0.0:53", .process_name = "x", .path = null, .command_line = null, .command_note = "", .identity_note = "" },
    };
    std.mem.sort(Occupier, &rows, {}, lessThan);

    try testing.expectEqualStrings("0.0.0.0:53", rows[0].local_address);
    try testing.expectEqualStrings("[::]:53", rows[1].local_address);
}
