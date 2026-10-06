//! The one seam: from a port to every Occupier of a Listening socket on it.
//!
//! Everything above this file — argument parsing, table layout, exit codes — is
//! platform independent and reaches the OS only through `lookup`.
//!
//! This file holds the dispatch and the row order. The Occupier contract itself
//! lives in occupier.zig, which has no platform in it. Keeping them apart is what
//! stops each adapter from importing the module that dispatches to it.

const std = @import("std");
const builtin = @import("builtin");
const occ = @import("occupier.zig");

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
pub fn lookup(io: std.Io, gpa: std.mem.Allocator, port: u16) LookupError![]occ.Occupier {
    const rows = try impl.lookup(io, gpa, port);
    // Row order is part of what a caller is promised, so the seam applies it.
    // Leaving it to each adapter is how a new platform ships rows in kernel
    // order and the promise quietly stops being true.
    std.sort.heap(occ.Occupier, rows, {}, occ.lessThan);
    return rows;
}
