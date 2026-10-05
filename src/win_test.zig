//! The live round-trip test from the spec: bind a Listening socket, look it up,
//! and assert the Occupier is this very process. It is also the regression test
//! for the elevation question — nothing here may need administrator rights.
const std = @import("std");
const which = @import("lookup.zig");

extern "ws2_32" fn WSAStartup(version: u16, data: *WsaData) c_int;
extern "ws2_32" fn WSACleanup() c_int;
extern "ws2_32" fn socket(af: i32, sock_type: i32, protocol: i32) callconv(.winapi) usize;
extern "ws2_32" fn bind(s: usize, addr: *const SockAddr, len: u32) c_int;
extern "ws2_32" fn listen(s: usize, backlog: c_int) c_int;
extern "ws2_32" fn getsockname(s: usize, addr: *SockAddr, len: *u32) c_int;
extern "ws2_32" fn closesocket(s: usize) c_int;

const WsaData = extern struct {
    version: u16,
    high: u16,
    desc: [257]u8,
};

const AF_INET: i32 = 2;
const SOCK_STREAM: i32 = 1;
const IPPROTO_TCP: i32 = 6;
const INVALID_SOCKET: usize = @bitCast(@as(isize, -1));

/// `struct sockaddr_in` as the 16 bytes Windows expects.
const SockAddr = extern struct {
    family: u16 = @intCast(AF_INET),
    /// Network byte order.
    port: u16 = 0,
    /// Network byte order; 0x0100007F is 127.0.0.1.
    addr: u32 = 0x0100007F,
    zero: [8]u8 = @splat(0),
};

/// A Listening socket on a port the kernel picked, held for the rest of the test.
const Bound = struct {
    sock: usize,
    port: u16,

    fn open() !Bound {
        var data: WsaData = undefined;
        try expectEq(0, WSAStartup(0x0202, &data), "WSAStartup");
        errdefer _ = WSACleanup();

        const s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (s == INVALID_SOCKET) return error.SocketFailed;
        errdefer _ = closesocket(s);

        // Port 0 asks the kernel for a free one, so the test can never collide.
        var addr = SockAddr{};
        try expectEq(0, bind(s, &addr, @sizeOf(SockAddr)), "bind");

        var bound: SockAddr = undefined;
        var len: u32 = @sizeOf(SockAddr);
        try expectEq(0, getsockname(s, &bound, &len), "getsockname");

        try expectEq(0, listen(s, 1), "listen");

        errdefer _ = WSACleanup();
        return .{ .sock = s, .port = std.mem.nativeToBig(u16, bound.port) };
    }

    fn close(self: Bound) void {
        _ = closesocket(self.sock);
        _ = WSACleanup();
    }
};

fn expectEq(expected: anytype, actual: anytype, what: []const u8) !void {
    if (expected != actual) {
        std.debug.print("{s}: expected {any}, got {any}\n", .{ what, expected, actual });
        return error.Unexpected;
    }
}

test "a bound Listening socket is Occupied by this process" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;

    const bound = try Bound.open();
    defer bound.close();

    const gpa = std.heap.page_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const rows = try which.lookup(threaded.io(), gpa, bound.port);
    defer gpa.free(rows);

    try std.testing.expect(rows.len > 0);
    const me = std.os.windows.GetCurrentProcessId();
    const port_suffix = try std.fmt.allocPrint(gpa, ":{d}", .{bound.port});
    defer gpa.free(port_suffix);

    var found = false;
    for (rows) |row| {
        if (row.pid != me) continue;
        // We bound loopback, so the address must be loopback and this exact port.
        try std.testing.expect(std.mem.startsWith(u8, row.local_address, "127.0.0.1"));
        try std.testing.expect(std.mem.endsWith(u8, row.local_address, port_suffix));
        found = true;
    }
    try std.testing.expect(found);
}