# which-port

Answers one question: which process is holding this TCP port right now.

```
> which-port 4711
ADDRESS       PID    PROCESS   PATH
0.0.0.0:4711  19912  pwsh.exe  C:\Program Files\PowerShell\7\pwsh.exe
[::]:4711     19912  pwsh.exe  C:\Program Files\PowerShell\7\pwsh.exe
```

You reached for `netstat -ano` and got every socket on the machine in a
fixed-width table you now have to re-read by eye. `Get-NetTCPConnection` is
slower and hands back objects whose property names you have to remember. The
Process Explorer dialog is several clicks away from the terminal error that
prompted the question. This is the one question, answered directly, in a script
you can branch on.

## Install

Grab the file for your platform from the [releases page](https://github.com/mmmmaharshi/which-port/releases),
or build it yourself. Either way it is one file with nothing beside it.

### Windows: unblock the download first

Windows will not run a downloaded executable it has not seen before, and it says
so with a "Windows protected your PC" dialog. That is SmartScreen reacting to an
unsigned binary, not a problem with this one — it happens to `fd`, `bat` and
`ripgrep` too until they are signed.

Clear it once per download:

```powershell
Unblock-File -Path .\which-port-x86_64-windows.exe
```

Then copy it somewhere on your `PATH`. Nothing is installed: no Program Files, no
registry, no uninstaller. Deleting the file is the uninstall.

### Linux and macOS

```sh
curl -LO https://github.com/mmmmaharshi/which-port/releases/latest/download/which-port-x86_64-linux-musl
chmod +x which-port-x86_64-linux-musl
sudo mv which-port-x86_64-linux-musl /usr/local/bin/which-port
```

The Linux build is statically linked, so it needs nothing installed beside it —
not even libc. Verify what you downloaded against the `SHA256SUMS` on the release
page:

```sh
sha256sum which-port-x86_64-linux-musl
```

### Building it yourself

```sh
zig build
```

That leaves one file, `zig-out/bin/which-port`, of about 500 KB, with nothing
beside it. Copy it onto your `PATH`. No runtime, no package manager, no
configuration.

To build every target a release attaches, from the same machine:

```sh
zig build all-targets
```

They land in `zig-out/release/`, each named for its target, so a release is a
directory listing rather than six hand-typed commands.

Works on Windows and Linux today, and needs neither an elevated shell nor root.

## Usage

```
usage: which-port <port>

Reports the Occupier of each Listening socket on <port>. Only Listening
sockets are reported; connection rows and UDP are not.

exit status:
  0  the port is Occupied
  1  the port is Free
  2  bad usage
  3  the socket table could not be read
```

The exit code carries the answer, so a script never has to parse the table:

```sh
which-port "$PORT"
case $? in
  1) echo "nothing is listening on $PORT" ;;
  2) echo "that is not a port number" ;;
  3) echo "could not read the socket table" ;;
esac
```

> [!NOTE]
> The Occupancy table goes to standard output and every prose line goes to
> standard error, so `which-port 8080 > out.txt` gives you a clean table and
> nothing else.

## What it reports

**Only Listening sockets.** A browser with fifty established connections on
your port does not bury the one row you care about, and a bound UDP socket is
never confused with a listening one.

**One row per socket, not per process.** A single process commonly holds both
an IPv4 and an IPv6 socket on the same port. You get two rows, and the Local
address column is the reason: it is how you tell whether the port is reachable
from outside the machine.

**Addresses always in full form.** `0.0.0.0` and `[::]` are printed as
themselves. Collapsing them to `*` would discard the one fact that makes a
dual-stack pair interpretable.

**Never a wrong Path.** When the operating system withholds an Occupier's
metadata from an unprivileged caller, you get the Occupier anyway, by PID and
socket, with a placeholder where the rest would go:

```
> which-port 135
ADDRESS      PID   PROCESS  PATH
0.0.0.0:135  1484  -        -
[::]:135     1484  -        -
```

and the reason on standard error, once per process rather than once per socket:

```
1484: identity unavailable, could not open the process (access denied, or it has exited)
```

This is the common case on Linux for an unprivileged caller, not a corner. A
blank Path is never an error, and the tool will not ask you to elevate.

**No escape codes.** Aligned columns with spaces, byte-identical piped and on a
terminal. Rows are ordered by PID, so two runs of the same query print the same
table.

## Checks

```sh
pwsh scripts/test-all.ps1
```

One command runs every suite this machine can: formatting, the four unit suites,
a compile of the binary itself, a compile of every shipped target, a live
round-trip on Windows, the Linux suite cross-compiled and run under WSL, and a
glossary check that fails the run if the code has drifted from the vocabulary in
[`CONTEXT.md`](CONTEXT.md).

`zig build test` runs just the four OS-free suites, for when you want the fast
loop.

To have that gate your commits, arm the hooks once:

```sh
git config core.hooksPath .githooks
```

`core.hooksPath` is local git config and does not travel with a clone, which is
why the command is not optional.

## Layout

| Path | What lives there |
| --- | --- |
| `src/lookup.zig` | The one seam, from a port to every Occupier of a Listening socket on it |
| `src/win.zig`, `src/lin.zig` | One adapter per platform behind that seam |
| `src/report.zig` | The table's exact bytes, and the notes that explain a `-` |
| `src/parse_proc.zig` | The Linux text parser, tested against a captured kernel table |
| `docs/adr/` | Why Zig, and why one platform shells out and two do not |

[`CONTEXT.md`](CONTEXT.md) is the glossary: the words this tool uses, and the
synonyms it has decided against.
