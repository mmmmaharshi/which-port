//! Windows Occupier lookup: `GetExtendedTcpTable` with
//! `TCP_TABLE_OWNER_PID_LISTENER`, which filters to Listening sockets in the
//! kernel, so no state filter of our own is needed.
//!
//! Everything here is hand-declared because Zig ships no bindings for it and we
//! deliberately do not want a Windows SDK dependency. See ADR 0002.

const std = @import("std");

// The Occupier contract, with no platform in it. This is the only import of it
// the adapter needs: the vocabulary and the two constructors both arrive here.
const occ = @import("occupier.zig");
const Occupier = occ.Occupier;

// Local addresses are formatted by the shared module so Windows, Linux and
// macOS print byte-identical output. See CONTEXT.md: Local address.
const addr = @import("addr.zig");

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

extern "ntdll" fn NtQueryInformationProcess(
    process: ?*anyopaque,
    information_class: u32,
    information: ?*anyopaque,
    information_length: u32,
    return_length: ?*u32,
) callconv(.winapi) i32;

const AF_INET = 2;
const AF_INET6 = 23;
/// TCP_TABLE_OWNER_PID_LISTENER: listeners only, with an owning pid.
const TCP_TABLE_OWNER_PID_LISTENER = 3;
const ERROR_INSUFFICIENT_BUFFER = 122;
const PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
/// ProcessCommandLineInformation. Internal to Windows (ADR 0002's
/// hand-declared pattern), present from Windows 8.1, and readable
/// with PROCESS_QUERY_LIMITED_INFORMATION -- the right the handle in
/// `describe` is already opened with.
const ProcessCommandLineInformation = 60;
const STATUS_INFO_LENGTH_MISMATCH: i32 = @bitCast(@as(u32, 0xC0000004));

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

/// The header of a `ProcessCommandLineInformation` answer. The
/// string it describes is not behind `buffer`: it follows the
/// header, inline in the same buffer.
const UnicodeString = extern struct {
    length: u16,
    maximum_length: u16,
    buffer: ?[*]u16,
};

pub const LookupError = Allocator.Error || error{TableUnavailable};

// --- entry point -------------------------------------------------------------

pub fn lookup(io: std.Io, gpa: Allocator, port: u16) LookupError![]Occupier {
    _ = io;
    var out: std.ArrayList(Occupier) = .empty;
    errdefer out.deinit(gpa);

    try collect4(gpa, &out, port);
    try collect6(gpa, &out, port);
    return out.toOwnedSlice(gpa);
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

// --- collectors --------------------------------------------------------------

fn collect4(gpa: Allocator, out: *std.ArrayList(Occupier), port: u16) LookupError!void {
    const rows = try fetch(gpa, AF_INET, Tcp4Row);
    defer gpa.free(rows);
    var buf: [addr.maxLen]u8 = undefined;
    for (rows) |row| {
        if (portOf(row.dwLocalPort) != port) continue;
        // Sized from addr.maxLen, so a wrong bound is a compile error here rather
        // than an unreachable branch that depends on the arithmetic.
        const local = addr.addr4(&buf, row.dwLocalAddr, port) catch unreachable;
        try out.append(gpa, try describe(gpa, local, row.dwOwningPid));
    }
}

fn collect6(gpa: Allocator, out: *std.ArrayList(Occupier), port: u16) LookupError!void {
    const rows = try fetch(gpa, AF_INET6, Tcp6Row);
    defer gpa.free(rows);
    var buf: [addr.maxLen]u8 = undefined;
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
        return occ.withheld(gpa, local_address, pid, "could not open the process (access denied, or it has exited)");
    }
    defer _ = CloseHandle(handle);

    var wide: [4096]u16 = undefined;
    var len: u32 = @intCast(wide.len);
    if (QueryFullProcessImageNameW(handle, 0, &wide, &len) == 0) {
        return occ.withheld(gpa, local_address, pid, "could not read the image path (access denied, or it has exited)");
    }

    const path = std.unicode.utf16LeToUtf8Alloc(gpa, wide[0..len]) catch
        return occ.withheld(gpa, local_address, pid, "the image path is not valid text");
    defer gpa.free(path);
    const command_line = commandLine(gpa, handle);
    defer if (command_line) |line| gpa.free(line);
    return occ.named(gpa, local_address, pid, path, command_line);
}

/// The command line of the process behind `handle`, or null
/// when the OS withholds it. The class is undocumented and
/// absent before Windows 8.1, so a refused query leaves the
/// Occupier named -- a named Occupier with a missing Command
/// line, not a withheld one. See occupier.named.
fn commandLine(gpa: Allocator, handle: ?*anyopaque) ?[]const u8 {
    // Ask for the size first, then fetch: the same two calls
    // `fetch` makes of `GetExtendedTcpTable`.
    var needed: u32 = 0;
    const probe = NtQueryInformationProcess(handle, ProcessCommandLineInformation, null, 0, &needed);
    if (probe != STATUS_INFO_LENGTH_MISMATCH or needed == 0) return null;

    const buffer = gpa.allocWithOptions(u8, needed, std.mem.Alignment.of(UnicodeString), null) catch return null;
    defer gpa.free(buffer);
    if (NtQueryInformationProcess(handle, ProcessCommandLineInformation, buffer.ptr, needed, &needed) != 0) return null;

    // Header first, then the string's own bytes. Length counts
    // bytes, so a header that overruns the buffer is refused
    // rather than read past it.
    const header: *const UnicodeString = @ptrCast(buffer.ptr);
    if (buffer.len < @sizeOf(UnicodeString) or header.length > buffer.len - @sizeOf(UnicodeString)) return null;
    const wide = @as([*]const u16, @ptrCast(buffer.ptr + @sizeOf(UnicodeString)))[0 .. header.length / 2];
    return std.unicode.utf16LeToUtf8Alloc(gpa, wide) catch null;
}

comptime {
    std.debug.assert(@sizeOf(Tcp4Row) == 24);
    std.debug.assert(@sizeOf(Tcp6Row) == 56);
    std.debug.assert(@offsetOf(Tcp6Row, "dwOwningPid") == 52);
    // The header is pointer-sized, so its size is 64-bit on a
    // 64-bit target: asserted relative to the target, not as a
    // number that holds on only one of them.
    std.debug.assert(@offsetOf(UnicodeString, "length") == 0);
    std.debug.assert(@offsetOf(UnicodeString, "maximum_length") == 2);
    std.debug.assert(@offsetOf(UnicodeString, "buffer") == @sizeOf(usize));
    std.debug.assert(@sizeOf(UnicodeString) == @sizeOf(usize) * 2);
}
