//! Windows Occupier lookup: `GetExtendedTcpTable` with
//! `TCP_TABLE_OWNER_PID_LISTENER`, which filters to Listening sockets in the
//! kernel, so no state filter of our own is needed.
//!
//! Everything here is hand-declared because Zig ships no bindings for it and we
//! deliberately do not want a Windows SDK dependency. See ADR 0002.

const std = @import("std");
const builtin = @import("builtin");
const Occupier = @import("lookup.zig").Occupier;

const Allocator = std.mem.Allocator;

// --- hand-declared Win32 -----------------------------------------------------

extern "iphlpapi" fn GetExtendedTcpTable(
    table: ?*anyopaque,
    size: *u32,
    order: i32,
    address_family: u32,
    table_class: u32,
    reserved: u32,
) callconv(.winapi) u32;

extern "kernel32" fn OpenProcess(access: u32, inherit_handle: i32, pid: u32) ?*anyopaque;
extern "kernel32" fn QueryFullProcessImageNameW(
    process: ?*anyopaque,
    flags: u32,
    name: [*]u16,
    name_len: *u32,
) i32;
extern "kernel32" fn CloseHandle(handle: ?*anyopaque) i32;

const AF_INET = 2;
const AF_INET6 = 23;
/// TCP_TABLE_OWNER_PID_LISTENER: listeners only, with an owning pid.
const TCP_TABLE_OWNER_PID_LISTENER = 3;
const ERROR_INSUFFICIENT_BUFFER = 122;
const PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

/// Read straight out of the MSVC headers. IPv4 and IPv6 use *different* row
/// structs, which is easy to get wrong: the IPv6 row leads with a 16-byte
/// address, not a DWORD.
const Tcp4Row = extern struct {
    dwState: u32,
    dwLocalAddr: u32,
    dwLocalPort: u32,
    dwRemoteAddr: u32,
    dwRemotePort: u32,
    dwOwningPid: u32,
};

const Tcp6Row = extern struct {
    ucLocalAddr: [16]u8,
    dwLocalScopeId: u32,
    dwLocalPort: u32,
    ucRemoteAddr: [16]u8,
    dwRemoteScopeId: u32,
    dwRemotePort: u32,
    dwState: u32,
    dwOwningPid: u32,
};

pub const LookupError = Allocator.Error || error{ TableUnavailable };

// --- entry point -------------------------------------------------------------

pub fn lookup(io: std.Io, gpa: Allocator, port: u16) LookupError![]Occupier {
    _ = io;
    var out: std.ArrayList(Occupier) = .empty;
    errdefer out.deinit(gpa);

    try collect4(gpa, &out, port);
    try collect6(gpa, &out, port);

    std.sort.heap(Occupier, out.items, {}, which.lessThan);
    return try out.toOwnedSlice(gpa);
}

// --- table fetch -------------------------------------------------------------

/// Ask for the table twice: once with no buffer to learn its size, then for
/// real. The size returned is a capacity, not an exact length, so rows are
/// counted from the table's own entry count.
fn fetch(gpa: Allocator, address_family: u32, comptime Row: type) LookupError![]Row {
    var needed: u32 = 0;
    const probe = GetExtendedTcpTable(null, &needed, 0, address_family, TCP_TABLE_OWNER_PID_LISTENER, 0);
    if (probe != ERROR_INSUFFICIENT_BUFFER and probe != 0) return error.TableUnavailable;
    if (needed == 0) return gpa.alloc(Row, 0);

    const words = try gpa.alloc(u32, @max(1, needed / @sizeOf(u32)));
    defer gpa.free(words);

    const got = GetExtendedTcpTable(words.ptr, &needed, 0, address_family, TCP_TABLE_OWNER_PID_LISTENER, 0);
    if (got != 0) return error.TableUnavailable;

    // Entry count is the first u32, followed by `count` fixed-size rows.
    const count = words[0];
    const bytes_after_header = @as(usize, needed) - @sizeOf(u32);
    const whole = bytes_after_header / @sizeOf(Row);
    return gpa.dupe(Row, @as([*]const Row, @ptrCast(words.ptr + 1))[0..@min(count, whole)]);
}

/// The port field is a DWORD holding the port in its low 16 bits, network byte
/// order.
fn portOf(raw: u32) u16 {
    return @byteSwap(@as(u16, @truncate(raw)));
}

// --- the seam's shared vocabulary ---------------------------------------------

// Local addresses are formatted by the shared module so Windows, Linux and
// macOS print byte-identical output. See CONTEXT.md: Local address.
const addr = @import("addr.zig");

// `withheld` and `lessThan` live beside Occupier so withholding metadata and
// row order are one contract, not one copy per platform.
const which = @import("lookup.zig");


// --- collectors --------------------------------------------------------------

fn collect4(gpa: Allocator, out: *std.ArrayList(Occupier), port: u16) LookupError!void {
    const rows = try fetch(gpa, AF_INET, Tcp4Row);
    defer gpa.free(rows);
    var buf: [64]u8 = undefined;
    for (rows) |row| {
        if (portOf(row.dwLocalPort) != port) continue;
        // A 64-byte buffer against a 46-byte worst case (`[xxxx:...:xxxx]:65535`),
        // so the address always fits and the error is unreachable by construction.
        const local = addr.addr4(&buf, row.dwLocalAddr, port) catch unreachable;
try out.append(gpa, try describe(gpa, local, row.dwOwningPid));
    }
}

fn collect6(gpa: Allocator, out: *std.ArrayList(Occupier), port: u16) LookupError!void {
    const rows = try fetch(gpa, AF_INET6, Tcp6Row);
    defer gpa.free(rows);
    var buf: [64]u8 = undefined;
    for (rows) |row| {
        if (portOf(row.dwLocalPort) != port) continue;
        const local = addr.addr6(&buf, row.ucLocalAddr, port) catch unreachable;
try out.append(gpa, try describe(gpa, local, row.dwOwningPid));
    }
}

// --- Occupier identity -------------------------------------------------------

/// Resolve one Occupier's identity. Every failure here is reported *in* the row
/// rather than as an error: the socket is occupied either way, and the pid is
/// already known. See CONTEXT.md, "Withheld identity".
fn describe(gpa: Allocator, local_address: []const u8, pid: u32) Allocator.Error!Occupier {
    const handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
    if (handle == null) {
        return which.withheld(gpa, local_address, pid, "could not open the process (access denied, or it has exited)");
    }
    defer _ = CloseHandle(handle);

    var wide: [4096]u16 = undefined;
    var len: u32 = @intCast(wide.len);
    if (QueryFullProcessImageNameW(handle, 0, &wide, &len) == 0) {
        return which.withheld(gpa, local_address, pid, "could not read the image path (access denied, or it has exited)");
    }

    const path = std.unicode.utf16LeToUtf8Alloc(gpa, wide[0..len]) catch
        return which.withheld(gpa, local_address, pid, "the image path is not valid text");
    // Exe name is the basename, including the extension.
    const name = std.fs.path.basename(path);
    return .{
        .pid = pid,
        .local_address = try gpa.dupe(u8, local_address),
        .process_name = try gpa.dupe(u8, name),
        .path = path,
        .identity_note = "",
    };
}

comptime {
    std.debug.assert(@sizeOf(Tcp4Row) == 24);
    std.debug.assert(@sizeOf(Tcp6Row) == 56);
    std.debug.assert(@offsetOf(Tcp6Row, "dwOwningPid") == 52);
}
