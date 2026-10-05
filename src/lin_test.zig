//! The Linux live round-trip test from the spec: bind a Listening socket, look
//! it up, and assert the Occupier is this very process. No root required.
//!
//! Bound through libc rather than std: Zig 0.17 has no `std.posix.socket` and its
//! replacement lives behind `std.Io.net`, which is more machinery than a test
//! needs. Built with `-lc`.
const std = @import("std");
const which = @import("lookup.zig");

extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn bind(fd: c_int, addr: *const SockAddr, len: c_int) c_int;
extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
extern "c" fn getsockname(fd: c_int, addr: *SockAddr, len: *c_int) c_int;
extern "c" fn close(fd: c_int) c_int;

/// `struct sockaddr_in` as 16 little-endian bytes.
const SockAddr = extern struct {
    family: u16 = 2, // AF_INET
    /// Network byte order.
    port: u16 = 0,
    /// Network byte order; 0x0100007F is 127.0.0.1.
    addr: u32 = 0x0100007F,
    zero: [8]u8 = @splat(0),
};

/// Bind a listener on a kernel-chosen loopback port and return it still open.
fn bindLoopback() !struct { fd: c_int, port: u16 } {
    const fd = socket(2, 1, 6);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = close(fd);

    var addr = SockAddr{};
    if (bind(fd, &addr, @sizeOf(SockAddr)) != 0) return error.BindFailed;
    if (listen(fd, 1) != 0) return error.ListenFailed;

    var bound: SockAddr = undefined;
    var len: c_int = @sizeOf(SockAddr);
    if (getsockname(fd, &bound, &len) != 0) return error.GetsocknameFailed;
    return .{ .fd = fd, .port = std.mem.nativeToBig(u16, bound.port) };
}

test "a bound Listening socket is Occupied by this process" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    const gpa = std.heap.page_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const listener = try bindLoopback();
    defer _ = close(listener.fd);

    const rows = try which.lookup(io, gpa, listener.port);
    defer gpa.free(rows);

    try std.testing.expect(rows.len > 0);
    const me = std.os.linux.getpid();
    const port_suffix = try std.fmt.allocPrint(gpa, ":{d}", .{listener.port});
    defer gpa.free(port_suffix);

    var found = false;
    for (rows) |row| {
        if (row.pid != me) continue;
        // We bound loopback, so the address must be loopback and this port.
        try std.testing.expect(std.mem.startsWith(u8, row.local_address, "127.0.0.1"));
        try std.testing.expect(std.mem.endsWith(u8, row.local_address, port_suffix));
        found = true;
    }
    try std.testing.expect(found);
}

test "a port nobody is listening on is Free" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    const gpa = std.heap.page_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    // Bind then release, so the port is known to have been free a moment ago.
    const listener = try bindLoopback();
    _ = close(listener.fd);

    const rows = try which.lookup(threaded.io(), gpa, listener.port);
    defer gpa.free(rows);
    try std.testing.expectEqual(@as(usize, 0), rows.len);
}