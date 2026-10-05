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
    return impl.lookup(io, gpa, port);
}
