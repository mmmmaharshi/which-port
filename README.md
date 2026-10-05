# which-port

Reports the process holding a TCP port.

```
> which-port 4711
ADDRESS       PID    PROCESS   PATH
0.0.0.0:4711  19912  pwsh.exe  C:\Program Files\PowerShell\7\pwsh.exe
[::]:4711     19912  pwsh.exe  C:\Program Files\PowerShell\7\pwsh.exe
```

One port in, one table out. The exit code carries the answer, so a script never
parses the text.

## Install

### Windows

```powershell
iwr -useb https://raw.githubusercontent.com/mmmmaharshi/which-port/master/scripts/install.ps1 | iex
```

The script downloads the latest release, verifies it against `SHA256SUMS`, clears
the download block, and adds the directory to your user `PATH`. It needs no
elevation and installs to `%LOCALAPPDATA%\Programs\which-port`.

Open a new terminal afterwards. A `PATH` change is not visible to the shell that
made it.

To pin a version, download the script and pass the argument:

```powershell
iwr -useb https://raw.githubusercontent.com/mmmmaharshi/which-port/master/scripts/install.ps1 -OutFile install.ps1
.\install.ps1 -Version v0.1.1
```

To choose the directory yourself, and skip the `PATH` change:

```powershell
.\install.ps1 -Dir C:\tools
```

### Linux

```sh
curl -LO https://github.com/mmmmaharshi/which-port/releases/latest/download/which-port-x86_64-linux-musl
chmod +x which-port-x86_64-linux-musl
sudo mv which-port-x86_64-linux-musl /usr/local/bin/which-port
```

Check the download against `SHA256SUMS` on the
[releases page](https://github.com/mmmmaharshi/which-port/releases):

```sh
sha256sum which-port-x86_64-linux-musl
```

The Linux build is statically linked, so it needs nothing beside it, not even
libc.

### Why Windows blocks the download

Windows shows a "Windows protected your PC" dialog before running any executable
it has not seen before. SmartScreen objects to the missing signature, not to this
binary. `fd`, `bat`, and `ripgrep` carry the same warning until they are signed.

If you download the `.exe` yourself, clear the block with:

```powershell
Unblock-File -Path .\which-port-x86_64-windows.exe
```

### What "installed" means

One file on your `PATH`. Nothing goes to Program Files, and there is no registry
entry, no uninstaller, and no background process. Delete the file to uninstall.

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

Branch on the exit code rather than the text:

```sh
which-port "$PORT"
case $? in
  0) echo "something is listening on $PORT" ;;
  1) echo "nothing is listening on $PORT" ;;
  2) echo "that is not a port number" ;;
  3) echo "could not read the socket table" ;;
esac
```

The table goes to standard output and the prose goes to standard error, so
`which-port 8080 > out.txt` gives you the table and nothing else.

## What it reports

### Only Listening sockets

Established connections and bound UDP sockets never appear. A browser holding
fifty connections to your port does not bury the row you care about.

### One row per socket, not per process

A process holding both an IPv4 and an IPv6 socket produces two rows. The Local
address column tells you whether the port is reachable from outside the machine,
which is the fact that makes a dual-stack pair readable.

### Addresses in full form

`0.0.0.0` and `[::]` print as themselves. Collapsing them to `*` would discard
the fact that tells you whether the bind was all interfaces or loopback only.

### A withheld process, not a missing one

An unprivileged caller often cannot read a process's name or path. `which-port`
reports the Occupier by PID and socket anyway, and prints `-` where the rest
would go:

```
> which-port 135
ADDRESS      PID   PROCESS  PATH
0.0.0.0:135  1484  -        -
[::]:135     1484  -        -
```

The reason goes to standard error, once per process rather than once per socket:

```
1484: identity unavailable, could not open the process (access denied, or it has exited)
```

On Linux this is the common case, not an edge case. A blank Path is never an
error, and the tool never asks you to elevate.

### Plain text, stable order

Columns are aligned with spaces, with no escape codes, so the table is
byte-identical piped and on a terminal. Rows sort by PID, so two runs of the same
query print the same table.

## Build from source

```sh
zig build
```

The binary lands in `zig-out/bin/`. Build every target a release attaches with:

```sh
zig build all-targets
```

Those binaries land in `zig-out/release/`, each named for its target. Requires
Zig 0.17 and no other dependency.

## Run the checks

```sh
pwsh scripts/test-all.ps1
```

The run covers formatting, four unit suites, a compile of the binary, a compile of
every shipped target, a live round-trip on Windows, the Linux suite cross-compiled
and run under WSL, and a glossary check against [`CONTEXT.md`](CONTEXT.md).

For a faster loop, `zig build test` runs the four OS-free unit suites alone.

Arm the hooks once to run the checks on every commit and push:

```sh
git config core.hooksPath .githooks
```

`core.hooksPath` is local git config, so a fresh clone needs that command before
the hooks run.

## Repository layout

| Path | Contents |
| --- | --- |
| `src/lookup.zig` | The seam: a port to every Occupier of a Listening socket on it |
| `src/win.zig`, `src/lin.zig` | One adapter per platform behind the seam |
| `src/report.zig` | The table bytes, and the notes that explain a `-` |
| `src/parse_proc.zig` | The Linux text parser, tested against a captured kernel table |
| `CONTEXT.md` | The glossary: the words this tool uses, and the synonyms it rejects |
| `docs/adr/` | Why Zig, and why one platform would shell out and two do not |
