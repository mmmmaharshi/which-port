//! Linux lookup: read the kernel's own tables and resolve ownership by socket
//! identity.
//!
//! `/proc/net/tcp` names no owner — only a socket inode. The kernel hands us the
//! other half of the identity in `/proc/<pid>/fd`, where the same inode appears
//! as a `socket:[N]` link. Joining the two is how we get from a Listening socket
//! to the Occupier holding it, with no subprocess and no root.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const parse = @import("parse_proc.zig");
const addr = @import("addr.zig");
const Occupier = @import("lookup.zig").Occupier;

const unresolved = "-";

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

    var buf: [1 << 20]u8 = undefined;
    var used: usize = 0;
    while (used < buf.len) {
        const n = try std.posix.read(file.handle, buf[used..]);
        if (n == 0) break;
        used += n;
    }
    return gpa.dupe(u8, buf[0..used]);
}

pub const LookupError = parse.ParseError ||
    Io.Dir.OpenError ||
    Io.Dir.AccessError ||
    Io.Dir.ReadFileAllocError ||
    Io.Dir.ReadLinkError ||
    Allocator.Error ||
    error{OwnerUnreadable};

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
    try findOwners(io, &root, matches.items, &pids);

    var out: std.ArrayList(Occupier) = .empty;
    errdefer out.deinit(gpa);
    var buf: [64]u8 = undefined;
    for (matches.items) |s| {
        const local = if (s.family6)
            addr.addr6(&buf, s.raw6, s.port) catch unreachable
        else
            addr.addr4(&buf, s.raw4, s.port) catch unreachable;
        const pid = pids.get(s.inode) orelse 0;
        if (pid == 0) {
            // The socket has no readable owner. Saying Free here would be a
            // lie, so say the lookup could not be completed instead.
            return error.OwnerUnreadable;
        }
        try out.append(gpa, try describe(io, gpa, &root, local, pid));
    }

    std.sort.heap(Occupier, out.items, {}, struct {
        fn lessThan(_: void, a: Occupier, b: Occupier) bool {
            if (a.pid != b.pid) return a.pid < b.pid;
            return std.mem.order(u8, a.local_address, b.local_address) == .lt;
        }
    }.lessThan);
    return out.toOwnedSlice(gpa);
}

/// Walk `/proc/<pid>/fd` until every wanted inode has an owner. Stopping early
/// matters: an unprivileged caller cannot read most processes' fd directories,
/// and a box running as root would otherwise pay for thousands of link reads.
fn findOwners(
    io: Io,
    root: *Io.Dir,
    wanted: []const parse.Socket,
    pids: *std.AutoHashMap(u64, u32),
) LookupError!void {
    var outstanding = wanted.len;
    var path_buf: [64]u8 = undefined;

    var entries = root.iterate();
    // A process can exit while we walk, which surfaces as an iteration error.
    // Skipping is safe: the OwnerUnreadable guard below still refuses to call a
    // socket with no readable owner Free.
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
    const exe_path = std.fmt.bufPrint(&path_buf, "{d}/exe", .{pid}) catch return withheld(gpa, local_address, pid, "the occupier exited before it could be described");

    var link_buf: [4096]u8 = undefined;
    const n = root.readLink(io, exe_path, &link_buf) catch
        return withheld(gpa, local_address, pid, "could not read the image path (access denied, or it has exited)");

    const path = link_buf[0..n];
    return .{
        .pid = pid,
        .local_address = try gpa.dupe(u8, local_address),
        .process_name = try gpa.dupe(u8, std.fs.path.basename(path)),
        .path = try gpa.dupe(u8, path),
        .path_note = "",
    };
}

fn withheld(gpa: Allocator, local_address: []const u8, pid: u32, note: []const u8) Allocator.Error!Occupier {
    return .{
        .pid = pid,
        .local_address = try gpa.dupe(u8, local_address),
        .process_name = unresolved,
        .path = null,
        .path_note = note,
    };
}