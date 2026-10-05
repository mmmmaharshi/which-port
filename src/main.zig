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
const exit_lookup_failed: u8 = 3;

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
    \\  3  the socket table could not be read
    \\
;

pub fn main(init: std.process.Init.Minimal) u8 {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `--help` and `-h` are a request for the help, not a bad argument: exit 0
    // on stdout so `which-port --help` in a pipeline is not an error.
    const argv = init.args.toSlice(arena) catch return exit_bad_usage;
    if (argv.len == 2 and isHelpFlag(argv[1])) {
        write(io, std.Io.File.stdout(), usage_text) catch {};
        return exit_occupied;
    }

    const port = parsePort(argv) catch |err| {
        const reason = describeArgProblem(err, argv, arena) catch "which-port: bad usage\n\n";
        return badUsage(io, reason);
    };

    const occupiers = which.lookup(io, arena, port) catch {
        write(io, std.Io.File.stderr(), "which-port: the socket table could not be read\n") catch {};
        return exit_lookup_failed;
    };

    if (occupiers.len == 0) {
        const msg = std.fmt.allocPrint(arena, "port {d} is free\n", .{port}) catch return exit_lookup_failed;
        write(io, std.Io.File.stderr(), msg) catch {};
        return exit_free;
    }

    write(io, std.Io.File.stdout(), render(arena, occupiers) catch return exit_lookup_failed) catch
        return exit_lookup_failed;

    // One note per Occupier whose identity the OS withheld, so the `-` is
    // explained rather than left as a mystery. Deduped by pid: an Occupier
    // holding both address families is one process, not two. See CONTEXT.md,
    // "Withheld identity" — withholding is never an error.
    var noted: std.ArrayList(?u32) = .empty;
    for (occupiers) |o| {
        if (o.identity_note.len == 0) continue;
        if (std.mem.indexOfScalar(?u32, noted.items, o.pid) != null) continue;
        noted.append(arena, o.pid) catch break;
        const pid_text = pidCell(arena, o.pid) catch break;
        const msg = std.fmt.allocPrint(
            arena,
            "{s}: identity unavailable, {s}\n",
            .{ pid_text, o.identity_note },
        ) catch break;
        write(io, std.Io.File.stderr(), msg) catch {};
    }
    return exit_occupied;
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

/// Name what was actually wrong with the arguments, so a mistake is obvious
/// without reading the syntax.
fn describeArgProblem(err: anyerror, argv: []const [:0]const u8, arena: Allocator) ![]const u8 {
    return switch (err) {
        error.NoArgument => "which-port: expected a port, got none\n\n",
        error.TooManyArguments => std.fmt.allocPrint(arena, "which-port: expected one port, got {d}\n\n", .{argv.len - 1}),
        error.NotANumber => std.fmt.allocPrint(arena, "which-port: \"{s}\" is not a number\n\n", .{argv[1]}),
        error.OutOfRange => std.fmt.allocPrint(arena, "which-port: \"{s}\" is not between 1 and 65535\n\n", .{argv[1]}),
        error.UnknownFlag => std.fmt.allocPrint(arena, "which-port: unknown option \"{s}\"\n\n", .{argv[1]}),
        else => "which-port: expected exactly one port, 1 to 65535\n\n",
    };
}

/// Exactly one port. No ranges, no service names, no second argument.
fn parsePort(argv: []const [:0]const u8) !u16 {
    if (argv.len < 2) return error.NoArgument;
    if (argv.len > 2) return error.TooManyArguments;
    const raw = argv[1];
    if (raw.len > 0 and raw[0] == '-') return error.UnknownFlag;
    if (raw.len == 0) return error.NotANumber;
    const port = std.fmt.parseUnsigned(u16, raw, 10) catch return error.NotANumber;
    if (port == 0) return error.OutOfRange;
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
        widths[1] = @max(widths[1], (try pidCell(arena, o.pid)).len);
        widths[2] = @max(widths[2], o.process_name.len);
        widths[3] = @max(widths[3], pathCell(o).len);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    try writeRow(arena, &out, headers, widths);
    for (occupiers) |o| {
        try writeRow(arena, &out, .{
            o.local_address,
            try pidCell(arena, o.pid),
            o.process_name,
            pathCell(o),
        }, widths);
    }
    return out.items;
}

/// An unknown pid is shown as the same placeholder as an unknown path, for the
/// same reason: the OS withheld it, which is not an error. See CONTEXT.md.
fn pidCell(arena: Allocator, pid: ?u32) ![]const u8 {
    const p = pid orelse return which.unresolved;
    return std.fmt.allocPrint(arena, "{d}", .{p});
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

