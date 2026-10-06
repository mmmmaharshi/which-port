# which-port

`which-port` answers one question: which process is holding a TCP port right
now, and where does it live. It is a single-purpose diagnostic for the moment a
port is already in use and you need to know what to kill, or what you forgot to
start.

## Language

**Port**:
A TCP port number on this machine.
_Avoid_: socket, endpoint

**Listening socket**:
A socket in the LISTEN state bound to a local port. This is the only thing
`which-port` considers.
_Avoid_: open port, active port, bound port, in-use port

**Occupier**:
The process holding a listening socket on a given port. One process can occupy
the same port more than once, once per socket.
_Avoid_: owner, "the process using the port" (that phrasing wrongly includes clients)

**Occupancy**:
The fact that a port has at least one listening socket. A port is occupied or
free, never in between.
_Avoid_: in use, taken, claimed, busy

**Free port**:
A port with no listening socket. Free does not mean bindable; something else
could be holding it in a state this tool does not report.
_Avoid_: unused, available, unbound

**Local address**:
The address a listening socket is bound to. `0.0.0.0` and `[::]` mean every
interface; `127.0.0.1` means loopback only. The same port usually has one
occupier but several local addresses.
_Avoid_: host, interface, NIC

**Path**:
The full filesystem path of the occupier's executable. This is optional
metadata: the OS withholds it from unprivileged callers for processes it
considers privileged, and `which-port` still reports the occupier without it.
A blank path is never an error.
_Avoid_: location, executable (the name is not the path)

**Command line**:
The argument vector an Occupier was started with, rendered as one line with the
arguments separated by spaces. This is what tells `node server.js` from
`node webpack-dev-server.js`. The Path does not, because both share one image.
No tool in this category reports it — see `docs/research/next-feature.md`.
_Avoid_: cmd
_Not on the list_: `argv` and `arguments` are legitimate words elsewhere.
`main.zig` uses `argv` for which-port's own arguments, which is a different
subject, and the glossary check works per file and cannot tell two subjects
apart. Banning the word would make the check wrong rather than strict. The
kernel's `/proc/<pid>/cmdline` file name is the same kind of proper noun: a
different subject the per-file check cannot tell apart from domain vocabulary,
so banning it would make the check wrong rather than strict.

**Withheld identity**:
The state of an occupier whose metadata the OS refused to an unprivileged
caller. On Windows that costs the Path *and* the process name, because a process
handle is the only way to ask either question. `which-port` reports the occupier
by PID and socket regardless, and says why the rest is missing. Withholding is
a permission boundary, not a bug: do not "fix" it by demanding elevation.
_Avoid_: permission error, lookup failure, inaccessible process
