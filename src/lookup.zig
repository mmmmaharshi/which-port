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
    pid: u32,
    /// The socket's own bind address in full form, never collapsed to a
    /// wildcard: `0.0.0.0:8080` or `[::]:8080`.
    local_address: []const u8,
    /// Basename of the Occupier's image, e.g. `node.exe`.
    process_name: []const u8,
    /// Full image path, or null when the OS withholds it. A null here is never
    /// an error — see `path_note`.
    path: ?[]const u8,
    /// Why `path` is null, e.g. "access denied". Empty when `path` is set.
    path_note: []const u8,
};

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