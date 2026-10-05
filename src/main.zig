//! which-port — name the Occupier of a TCP port.
//!
//! The Occupancy table goes to stdout; prose goes to stderr. That split is the
//! contract that lets `which-port 8080 > out.txt` capture data and never prose.

const std = @import("std");
const builtin = @import("builtin");
const which = @import("lookup.zig");

const Allocator = std.mem.Allocator;

const exit_occupied: u8 = 0;
const exit_free: u8 = 1;
const exit_bad_usage: u8 = 2;

const usage_text =
    \\usage: which-port <port>
    \\
    \\Reports the Occupier of each Listening socket on <port>. Only Listening
    \\sockets are reported; connection rows and UDP are not.
    \\
    \\exit status:
    \\  0  the port is Occupied
    \\  1  the port is Free
    \\  2  bad usage
    \\
;

pub fn main() u8 {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const port = parsePort(arena) catch {
        return badUsage(io, "which-port: expected exactly one port, 1 to 65535\n\n");
    };

    const occupiers = which.lookup(arena, port) catch {
        write(io, std.Io.File.stderr(), "which-port: the socket table could not be read\n") catch {};
        return exit_bad_usage;
    };

    if (occupiers.len == 0) {
        const msg = std.fmt.allocPrint(arena, "port {d} is free\n", .{port}) catch return exit_bad_usage;
        write(io, std.Io.File.stderr(), msg) catch {};
        return exit_free;
    }

    write(io, std.Io.File.stdout(), render(arena, occupiers) catch return exit_bad_usage) catch
        return exit_bad_usage;

    // One note per Occupier whose identity the OS withheld, so the `-` is
    // explained rather than left as a mystery. Deduped by pid: an Occupier
    // holding both address families is one process, not two. See CONTEXT.md:
    // never an error.
    var noted: std.ArrayList(u32) = .empty;
    for (occupiers) |o| {
        if (o.path != null) continue;
        if (std.mem.indexOfScalar(u32, noted.items, o.pid) != null) continue;
        noted.append(arena, o.pid) catch break;
        const msg = std.fmt.allocPrint(
            arena,
            "pid {d}: identity unavailable, {s}\n",
            .{ o.pid, o.path_note },
        ) catch break;
        write(io, std.Io.File.stderr(), msg) catch {};
    }
    return exit_occupied;
}

/// Exactly one port. No ranges, no service names, no second argument.
fn parsePort(arena: Allocator) !u16 {
    const argv = try commandLine(arena);
    if (argv.len != 2) return error.BadUsage;
    const raw = argv[1];
    if (raw.len == 0 or raw[0] == '-') return error.BadUsage;
    const port = std.fmt.parseUnsigned(u16, raw, 10) catch return error.BadUsage;
    if (port == 0) return error.BadUsage;
    return port;
}

fn badUsage(io: std.Io, reason: []const u8) u8 {
    write(io, std.Io.File.stderr(), reason) catch {};
    write(io, std.Io.File.stderr(), usage_text) catch {};
    return exit_bad_usage;
}

/// `ADDRESS PID PROCESS PATH`, one row per socket, columns aligned with spaces.
/// No escape codes, so the table is byte-identical piped and on a terminal.
fn render(arena: Allocator, occupiers: []const which.Occupier) ![]u8 {
    const headers = [_][]const u8{ "ADDRESS", "PID", "PROCESS", "PATH" };

    var widths: [headers.len]usize = undefined;
    for (headers, 0..) |h, i| widths[i] = h.len;
    for (occupiers) |o| {
        widths[0] = @max(widths[0], o.local_address.len);
        widths[1] = @max(widths[1], std.fmt.count("{d}", .{o.pid}));
        widths[2] = @max(widths[2], o.process_name.len);
        widths[3] = @max(widths[3], pathCell(o).len);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    try writeRow(arena, &out, headers, widths);
    for (occupiers) |o| {
        try writeRow(arena, &out, .{
            o.local_address,
            try std.fmt.allocPrint(arena, "{d}", .{o.pid}),
            o.process_name,
            pathCell(o),
        }, widths);
    }
    return out.items;
}

fn pathCell(o: which.Occupier) []const u8 {
    return o.path orelse "-";
}

/// Two spaces between columns, no trailing padding: the last column is the
/// Path and trailing spaces would only survive into a redirected file.
fn writeRow(
    arena: Allocator,
    out: *std.ArrayList(u8),
    fields: [4][]const u8,
    widths: [4]usize,
) !void {
    for (fields, widths, 0..) |f, w, i| {
        if (i > 0) try out.appendSlice(arena, "  ");
        try out.appendSlice(arena, f);
        if (i + 1 < fields.len) {
            try out.appendNTimes(arena, ' ', w - f.len);
        }
    }
    try out.append(arena, '\n');
}

fn write(io: std.Io, file: std.Io.File, bytes: []const u8) !void {
    try file.writeStreamingAll(io, bytes);
}

const windows = struct {
    extern "kernel32" fn GetCommandLineW() [*:0]const u16;
};

fn commandLine(arena: Allocator) ![]const [:0]const u8 {
    const Args = std.process.Args;
    const vector: Args.Vector = switch (builtin.os.tag) {
        .windows => std.mem.span(windows.GetCommandLineW()),
        // The POSIX command line arrives with the /proc ticket.
        else => @compileError("argv on " ++ @tagName(builtin.os.tag) ++ " arrives with its own ticket"),
    };
    return (Args{ .vector = vector }).toSlice(arena);
}