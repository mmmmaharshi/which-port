//! Linux lookup: read the kernel's own tables and resolve ownership by socket
//! identity.
//!
//! `/proc/net/tcp` names no process — only a socket inode. The kernel hands us
//! the other half of the identity in `/proc/<pid>/fd`, where the same inode
//! appears as a `socket:[N]` link. Joining the two is how we get from a Listening
//! socket to the Occupier holding it, with no subprocess and no root.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const occ = @import("occupier.zig");
const parse = @import("parse_proc.zig");
const addr = @import("addr.zig");
const Occupier = occ.Occupier;

/// Read a procfs file into memory.
///
/// Not `Io.Dir.readFileAlloc`: procfs reports a file size of zero, so std's
/// size-based reader hits `EndOfStream` before reading anything and hands back
/// an empty slice *without an error*. That turns a Live socket into "port is
/// free", silently — the quietest wrong answer this tool can give. So loop on
/// the raw read, which asks the kernel for bytes rather than trusting a length.
fn readProcFile(io: Io, root: Io.Dir, sub_path: []const u8, gpa: Allocator) LookupError![]u8 {
    var file = try root.openFile(io, sub_path, .{});
    defer file.close(io);

    // Grown on demand rather than reserved up front: these tables are a few KB,
    // and a fixed 1 MiB buffer on the stack is a poor trade in a container.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = try std.posix.read(file.handle, &chunk);
        if (n == 0) break;
        try out.appendSlice(gpa, chunk[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

pub const LookupError = parse.ParseError ||
    Io.Dir.OpenError ||
    Io.Dir.AccessError ||
    std.Io.File.OpenError ||
    std.Io.File.Reader.Error ||
    Io.Dir.ReadLinkError ||
    Allocator.Error;

/// Every Occupier holding a Listening socket on `port`.
pub fn lookup(io: Io, gpa: Allocator, port: u16) LookupError![]Occupier {
    var sockets: std.ArrayList(parse.Socket) = .empty;
    defer sockets.deinit(gpa);

    var root = try Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true });
    defer root.close(io);

    // Both families, read separately: exactly the shape the Windows table takes,
    // and what makes a dual-stack Occupier two rows rather than one.
    for ([_][]const u8{ "net/tcp", "net/tcp6" }) |name| {
        const text = try readProcFile(io, root, name, gpa);
        defer gpa.free(text);
        try parse.parse(gpa, text, &sockets);
    }

    var matches: std.ArrayList(parse.Socket) = .empty;
    defer matches.deinit(gpa);
    for (sockets.items) |s| {
        if (s.port == port) try matches.append(gpa, s);
    }
    if (matches.items.len == 0) return gpa.alloc(Occupier, 0);

    var pids: std.AutoHashMap(u64, u32) = .init(gpa);
    defer pids.deinit();
    try attribute(io, &root, matches.items, &pids);

    var out: std.ArrayList(Occupier) = .empty;
    errdefer out.deinit(gpa);
    var buf: [addr.maxLen]u8 = undefined;
    for (matches.items) |s| {
        const local = if (s.family6)
            addr.addr6(&buf, s.raw6, s.port) catch unreachable
        else
            addr.addr4(&buf, s.raw4, s.port) catch unreachable;
        // A Listening socket whose Occupier we could not name is still Occupied,
        // and an unprivileged caller cannot read most processes' fd directories
        // — so this is the common case, not a corner. Report the socket and say
        // the process is unknown. Calling it Free would be a lie. See CONTEXT.md.
        const pid = pids.get(s.inode);
        if (pid == null) {
            try out.append(gpa, try occ.withheld(gpa, local, null, "the holding process could not be identified (access denied, or it has exited)"));
            continue;
        }
        try out.append(gpa, try describe(io, gpa, &root, local, pid.?));
    }

    return out.toOwnedSlice(gpa);
}

/// Walk `/proc/<pid>/fd` until every wanted inode has been attributed to a
/// process. Stopping early matters: an unprivileged caller cannot read most
/// processes' fd directories, and a box running as root would otherwise pay for
/// thousands of link reads.
fn attribute(
    io: Io,
    root: *Io.Dir,
    wanted: []const parse.Socket,
    pids: *std.AutoHashMap(u64, u32),
) LookupError!void {
    var outstanding = wanted.len;
    var path_buf: [64]u8 = undefined;

    var entries = root.iterate();
    // A process can exit while we walk, which surfaces as an iteration error.
    // Skipping is safe: the caller reports any socket still unattributed rather
    // than calling it Free.
    while (entries.next(io) catch null) |entry| {
        if (outstanding == 0) return;
        const pid = std.fmt.parseUnsigned(u32, entry.name, 10) catch continue;
        const path = std.fmt.bufPrint(&path_buf, "{d}/fd", .{pid}) catch continue;

        var fd_dir = root.openDir(io, path, .{ .iterate = true }) catch continue;
        defer fd_dir.close(io);

        var fds = fd_dir.iterate();
        while (fds.next(io) catch null) |fd| {
            // readLink resolves against fd_dir, which is already <pid>/fd.
            var link_buf: [64]u8 = undefined;
            const n = fd_dir.readLink(io, fd.name, &link_buf) catch continue;
            const link = link_buf[0..n];
            if (!std.mem.startsWith(u8, link, "socket:[")) continue;
            if (!std.mem.endsWith(u8, link, "]")) continue;
            const inode = std.fmt.parseUnsigned(u64, link["socket:[".len .. link.len - 1], 10) catch continue;

            for (wanted) |s| {
                if (s.inode != inode) continue;
                if (pids.contains(inode)) continue;
                try pids.put(inode, pid);
                outstanding -= 1;
            }
        }
    }
}

/// Resolve one Occupier's identity from `/proc/<pid>`. Every failure is reported
/// *in* the row rather than as an error: the socket is occupied either way, and
/// the pid is already known. See CONTEXT.md.
fn describe(io: Io, gpa: Allocator, root: *Io.Dir, local_address: []const u8, pid: u32) LookupError!Occupier {
    var path_buf: [64]u8 = undefined;
    const exe_path = std.fmt.bufPrint(&path_buf, "{d}/exe", .{pid}) catch
        return occ.withheld(gpa, local_address, pid, "the Occupier exited before it could be described");

    var link_buf: [4096]u8 = undefined;
    const n = root.readLink(io, exe_path, &link_buf) catch
        return occ.withheld(gpa, local_address, pid, "could not read the image path (access denied, or it has exited)");

    const path = link_buf[0..n];

    // The Command line is optional on a named Occupier: the OS may
    // refuse it, or there may be none to give, and neither turns a
    // named Occupier into a withheld one. See occupier.named.
    const command_line = try readCommandLine(io, gpa, root, pid);
    defer if (command_line) |c| gpa.free(c);
    const command_note = if (command_line == null)
        "could not read the command line (access denied, or it has exited)"
    else
        "";
    return occ.named(gpa, local_address, pid, path, command_line, command_note);
}

/// The Occupier's command line, or null when the OS gives none.
///
/// The kernel keeps it under `/proc/<pid>` as the argument
/// vector, NUL-terminated: one NUL between arguments, one
/// after the last. The separators become spaces and the
/// trailing NUL is dropped, so the line ends with the last
/// argument and nothing else is added — the arguments as
/// one line, the same shape Windows reports, though not
/// always the same bytes. A read that fails (the process
/// exited, or hidepid is in force) and an empty file (a
/// kernel thread) both mean null, and neither is an error:
/// the socket is Occupied either way. See CONTEXT.md,
/// "Command line".
fn readCommandLine(io: Io, gpa: Allocator, root: *Io.Dir, pid: u32) LookupError!?[]u8 {
    var path_buf: [64]u8 = undefined;
    const sub_path = std.fmt.bufPrint(&path_buf, "{d}/cmdline", .{pid}) catch return null;

    // readProcFile rather than a size-based reader: procfs reports
    // a size of zero, which would read as an empty command line.
    const raw = readProcFile(io, root.*, sub_path, gpa) catch return null;
    defer gpa.free(raw);

    var end = raw.len;
    while (end > 0 and raw[end - 1] == 0) end -= 1;
    if (end == 0) return null;
    for (raw[0..end]) |*byte| {
        if (byte.* == 0) byte.* = ' ';
    }
    return try gpa.dupe(u8, raw[0..end]);
}
