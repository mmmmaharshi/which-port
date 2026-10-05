//! which-port — name the Occupier of a TCP port.
//!
//! The Occupancy table goes to stdout; prose goes to stderr. That split is the
//! contract that lets `which-port 8080 > out.txt` capture data and never prose.

const std = @import("std");
const builtin = @import("builtin");
const which = @import("lookup.zig");
const report = @import("report.zig");

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

    write(io, std.Io.File.stdout(), report.table(arena, occupiers) catch return exit_lookup_failed) catch
        return exit_lookup_failed;

    // One note per Occupier whose identity the OS withheld, so the `-` is
    // explained rather than left as a mystery. Deduped by pid: an Occupier
    // holding both address families is one process, not two. See CONTEXT.md,
    // "Withheld identity" — withholding is never an error.
    for (report.identityNotes(arena, occupiers) catch return exit_lookup_failed) |n| {
        write(io, std.Io.File.stderr(), n) catch {};
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

fn write(io: std.Io, file: std.Io.File, bytes: []const u8) !void {
    try file.writeStreamingAll(io, bytes);
}
