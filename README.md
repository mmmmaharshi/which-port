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

Open a new terminal afterwards. A `PATH` change is not visible to the shell that
made it.

### Linux

```sh
curl -LO https://github.com/mmmmaharshi/which-port/releases/latest/download/which-port-x86_64-linux-musl
chmod +x which-port-x86_64-linux-musl
sudo mv which-port-x86_64-linux-musl /usr/local/bin/which-port
```

Or grab the binary for your platform from the
[releases page](https://github.com/mmmmaharshi/which-port/releases).

### If Windows blocks the download

Windows shows a "Windows protected your PC" dialog before running any executable
it has not seen before. The warning is about the missing signature, not about this
binary. The install script clears it for you. If you downloaded the `.exe`
yourself:

```powershell
Unblock-File -Path .\which-port-x86_64-windows.exe
```

## Usage

```
usage: which-port <port>

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

## Reading the output

**Two rows for one port** means the process holds both an IPv4 and an IPv6 socket.
The address column tells you whether the port is reachable from outside the
machine.

**A `-`** means your account cannot read that process's name and path. Windows
withholds both, and Linux withholds them for most processes. The Occupier is still
reported by PID and socket, and the reason goes to standard error:

```
1484: identity unavailable, could not open the process (access denied, or it has exited)
```

**Only Listening sockets appear.** Established connections and bound UDP sockets
never do, so a busy browser does not bury the row you care about.

**Rows sort by PID** and columns are aligned with plain spaces, so two runs of the
same query print identical output.

## Uninstall

Delete the file and remove its directory from your `PATH`. There is no registry
entry, no uninstaller, and no background process.

---

Working on the code? See [`build.zig`](build.zig),
[`scripts/test-all.ps1`](scripts/test-all.ps1),
[`CONTEXT.md`](CONTEXT.md), and [`docs/adr/`](docs/adr/).
