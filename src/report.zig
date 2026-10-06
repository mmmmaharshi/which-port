//! Rendering the Occupancy table: the exact bytes that go to stdout, and the
//! per-process notes that go to stderr.
//!
//! Both live here so the "-" that stands for a withheld value is written once.
//! See CONTEXT.md, "Withheld identity".

const std = @import("std");
const testing = std.testing;
const occ = @import("occupier.zig");
const Occupier = occ.Occupier;
const Allocator = std.mem.Allocator;

/// `ADDRESS PID PROCESS PATH COMMAND`, one row per socket, columns
/// aligned with spaces. No escape codes, so the table is byte-identical
/// piped and on a terminal.
pub fn table(gpa: Allocator, occupiers: []const Occupier) ![]u8 {
    const headers = [_][]const u8{ "ADDRESS", "PID", "PROCESS", "PATH", "COMMAND" };

    var widths: [headers.len]usize = undefined;
    for (headers, 0..) |h, i| widths[i] = h.len;
    // A pid is at most ten digits, so the cell is formatted into a scratch
    // buffer rather than allocated: the caller's allocator owns only the
    // returned table.
    var scratch: [16]u8 = undefined;
    for (occupiers) |o| {
        widths[0] = @max(widths[0], o.local_address.len);
        widths[1] = @max(widths[1], (try pidCell(&scratch, o.pid)).len);
        widths[2] = @max(widths[2], o.process_name.len);
        widths[3] = @max(widths[3], pathCell(o).len);
        widths[4] = @max(widths[4], commandCell(o).len);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try writeRow(gpa, &out, headers, widths);
    for (occupiers) |o| {
        try writeRow(gpa, &out, .{
            o.local_address,
            try pidCell(&scratch, o.pid),
            o.process_name,
            pathCell(o),
            commandCell(o),
        }, widths);
    }
    return out.toOwnedSlice(gpa);
}

/// An unknown pid is shown as the same placeholder as an unknown path, for the
/// same reason: the OS withheld it, which is not an error. See CONTEXT.md.
fn pidCell(buf: []u8, pid: ?u32) ![]const u8 {
    const p = pid orelse return occ.unresolved;
    return std.fmt.bufPrint(buf, "{d}", .{p});
}

fn pathCell(o: Occupier) []const u8 {
    return o.path orelse occ.unresolved;
}

/// A command line the OS withholds is the same placeholder as a path it
/// withholds: not an error. See CONTEXT.md.
fn commandCell(o: Occupier) []const u8 {
    return o.command_line orelse occ.unresolved;
}

/// One line per Occupier whose identity or Command line the OS
/// withheld, deduped by pid, each already newline-terminated so the
/// caller only has to write it.
///
/// Withholding is a permission boundary, not a failure, so this never returns
/// an error for its own sake: an empty result simply means every Occupier was
/// named in full.
pub fn notes(gpa: Allocator, occupiers: []const Occupier) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (lines.items) |n| gpa.free(n);
        lines.deinit(gpa);
    }
    var noted: std.ArrayList(?u32) = .empty;
    defer noted.deinit(gpa);
    var scratch: [16]u8 = undefined;

    for (occupiers) |o| {
        if (std.mem.indexOfScalar(?u32, noted.items, o.pid) != null) continue;
        // One note per pid, and the identity note wins when an Occupier
        // carries both, which only a hand-built literal can: it is the
        // one that explains the whole row.
        if (o.identity_note.len != 0) {
            try noted.append(gpa, o.pid);
            try lines.append(gpa, try std.fmt.allocPrint(gpa, "{s}: identity unavailable, {s}\n", .{
                try pidCell(&scratch, o.pid),
                o.identity_note,
            }));
        } else if (o.command_note.len != 0) {
            try noted.append(gpa, o.pid);
            try lines.append(gpa, try std.fmt.allocPrint(gpa, "{s}: command line unavailable, {s}\n", .{
                try pidCell(&scratch, o.pid),
                o.command_note,
            }));
        }
    }
    return lines.toOwnedSlice(gpa);
}

/// Two spaces between columns, no trailing padding: the last column is
/// the Command line and trailing spaces would only survive into a
/// redirected file.
fn writeRow(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    fields: [5][]const u8,
    widths: [5]usize,
) !void {
    for (fields, widths, 0..) |f, w, i| {
        if (i > 0) try out.appendSlice(gpa, "  ");
        try out.appendSlice(gpa, f);
        if (i + 1 < fields.len) {
            try out.appendNTimes(gpa, ' ', w - f.len);
        }
    }
    try out.append(gpa, '\n');
}

test "one Occupier renders the header and one aligned row" {
    const gpa = testing.allocator;
    const rows = [_]Occupier{.{
        .pid = 17236,
        .local_address = "0.0.0.0:8080",
        .process_name = "node.exe",
        .path = "C:\\node.exe",
        .command_line = "node server.js",
        .identity_note = "",
        .command_note = "",
    }};

    const out = try table(gpa, &rows);
    defer gpa.free(out);

    try testing.expectEqualStrings(
        "ADDRESS       PID    PROCESS   PATH         COMMAND\n" ++
            "0.0.0.0:8080  17236  node.exe  C:\\node.exe  node server.js\n",
        out,
    );
}

// Withheld identity is not an error and never hides the Occupier: the socket is
// still reported, with `-` where the OS would not name something. See
// CONTEXT.md.
test "a withheld pid and path both render as the placeholder" {
    const gpa = testing.allocator;
    const rows = [_]Occupier{.{
        .pid = null,
        .local_address = "0.0.0.0:8080",
        .process_name = occ.unresolved,
        .path = null,
        .command_line = null,
        .identity_note = "the holding process could not be identified",
        .command_note = "",
    }};

    const out = try table(gpa, &rows);
    defer gpa.free(out);

    try testing.expectEqualStrings(
        "ADDRESS       PID  PROCESS  PATH  COMMAND\n" ++
            "0.0.0.0:8080  -    -        -     -\n",
        out,
    );
}

// A named Occupier can still be missing its Command line: the OS
// withholding it is not a withheld identity, so the rest of the
// row stands and only COMMAND carries the placeholder. See
// CONTEXT.md.
test "a named Occupier with a withheld command line renders the placeholder" {
    const gpa = testing.allocator;
    const rows = [_]Occupier{.{
        .pid = 4242,
        .local_address = "0.0.0.0:3000",
        .process_name = "python.exe",
        .path = "C:\\python\\python.exe",
        .command_line = null,
        .identity_note = "",
        .command_note = "",
    }};

    const out = try table(gpa, &rows);
    defer gpa.free(out);

    try testing.expectEqualStrings(
        "ADDRESS       PID   PROCESS     PATH                  COMMAND\n" ++
            "0.0.0.0:3000  4242  python.exe  C:\\python\\python.exe  -\n",
        out,
    );
}

// One Occupier can hold both address families, so a dual-stack port produces two
// rows and two of the same note. The note is per process: deduped by pid, or the
// same explanation is printed twice for one thing that went wrong once.
test "a dual-stack pair with one withheld identity yields one note" {
    const gpa = testing.allocator;
    const note = "could not read the image path (access denied, or it has exited)";
    const rows = [_]Occupier{
        .{
            .pid = 53,
            .local_address = "0.0.0.0:53",
            .process_name = "systemd",
            .path = null,
            .command_line = null,
            .command_note = "",
            .identity_note = note,
        },
        .{
            .pid = 53,
            .local_address = "[::]:53",
            .process_name = "systemd",
            .path = null,
            .command_line = null,
            .command_note = "",
            .identity_note = note,
        },
    };

    const lines = try notes(gpa, &rows);
    defer {
        for (lines) |n| gpa.free(n);
        gpa.free(lines);
    }

    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqualStrings("53: identity unavailable, " ++ note ++ "\n", lines[0]);
}

// A named Occupier can be missing only its Command line: the row stands
// and the note says why the `-` in COMMAND is there. The expected line
// is written whole rather than built from the same parts as the
// renderer, so a change to either side fails here.
test "a named occupier with a withheld command line yields one note" {
    const gpa = testing.allocator;
    const rows = [_]Occupier{.{
        .pid = 4242,
        .local_address = "0.0.0.0:3000",
        .process_name = "node.exe",
        .path = "C:\\node.exe",
        .command_line = null,
        .identity_note = "",
        .command_note = "could not read the command line (access denied, or it has exited)",
    }};

    const lines = try notes(gpa, &rows);
    defer {
        for (lines) |n| gpa.free(n);
        gpa.free(lines);
    }

    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqualStrings("4242: command line unavailable, could not read the command line (access denied, or it has exited)\n", lines[0]);
}
