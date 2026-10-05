//! Rendering the Occupancy table: the exact bytes that go to stdout, and the
//! per-process notes that go to stderr.
//!
//! Both live here so the "-" that stands for a withheld value is written once.
//! See CONTEXT.md, "Withheld identity".

const std = @import("std");
const testing = std.testing;
const which = @import("lookup.zig");
const Occupier = which.Occupier;
const Allocator = std.mem.Allocator;

/// `ADDRESS PID PROCESS PATH`, one row per socket, columns aligned with spaces.
/// No escape codes, so the table is byte-identical piped and on a terminal.
pub fn table(gpa: Allocator, occupiers: []const Occupier) ![]u8 {
    const headers = [_][]const u8{ "ADDRESS", "PID", "PROCESS", "PATH" };

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
        }, widths);
    }
    return out.toOwnedSlice(gpa);
}

/// An unknown pid is shown as the same placeholder as an unknown path, for the
/// same reason: the OS withheld it, which is not an error. See CONTEXT.md.
fn pidCell(buf: []u8, pid: ?u32) ![]const u8 {
    const p = pid orelse return which.unresolved;
    return std.fmt.bufPrint(buf, "{d}", .{p});
}

fn pathCell(o: Occupier) []const u8 {
    return o.path orelse which.unresolved;
}

/// One line per Occupier whose identity the OS withheld, deduped by pid, each
/// already newline-terminated so the caller only has to write it.
///
/// Withholding is a permission boundary, not a failure, so this never returns
/// an error for its own sake: an empty result simply means every Occupier was
/// named in full.
pub fn identityNotes(gpa: Allocator, occupiers: []const Occupier) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (lines.items) |n| gpa.free(n);
        lines.deinit(gpa);
    }
    var noted: std.ArrayList(?u32) = .empty;
    defer noted.deinit(gpa);
    var scratch: [16]u8 = undefined;

    for (occupiers) |o| {
        if (o.identity_note.len == 0) continue;
        if (std.mem.indexOfScalar(?u32, noted.items, o.pid) != null) continue;
        try noted.append(gpa, o.pid);
        try lines.append(gpa, try std.fmt.allocPrint(gpa, "{s}: identity unavailable, {s}\n", .{
            try pidCell(&scratch, o.pid),
            o.identity_note,
        }));
    }
    return lines.toOwnedSlice(gpa);
}

/// Two spaces between columns, no trailing padding: the last column is the
/// Path and trailing spaces would only survive into a redirected file.
fn writeRow(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    fields: [4][]const u8,
    widths: [4]usize,
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
        .identity_note = "",
    }};

    const out = try table(gpa, &rows);
    defer gpa.free(out);

    try testing.expectEqualStrings(
        "ADDRESS       PID    PROCESS   PATH\n" ++
            "0.0.0.0:8080  17236  node.exe  C:\\node.exe\n",
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
        .process_name = which.unresolved,
        .path = null,
        .identity_note = "the holding process could not be identified",
    }};

    const out = try table(gpa, &rows);
    defer gpa.free(out);

    try testing.expectEqualStrings(
        "ADDRESS       PID  PROCESS  PATH\n" ++
            "0.0.0.0:8080  -    -        -\n",
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
            .identity_note = note,
        },
        .{
            .pid = 53,
            .local_address = "[::]:53",
            .process_name = "systemd",
            .path = null,
            .identity_note = note,
        },
    };

    const notes = try identityNotes(gpa, &rows);
    defer {
        for (notes) |n| gpa.free(n);
        gpa.free(notes);
    }

    try testing.expectEqual(@as(usize, 1), notes.len);
    try testing.expectEqualStrings("53: identity unavailable, " ++ note ++ "\n", notes[0]);
}
