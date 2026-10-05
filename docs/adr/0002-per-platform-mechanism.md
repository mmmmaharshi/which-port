# Native APIs on Windows and Linux, a subprocess only on macOS

Each platform resolves port-to-PID a different way. Windows calls
`GetExtendedTcpTable` and Linux reads `/proc/net/tcp{,6}` and then matches socket
inodes against `/proc/<pid>/fd`, both in-process; macOS shells out to
`lsof -nP -iTCP -sTCP:LISTEN` because it has no non-root native equivalent. The
unevenness is deliberate. Shelling out everywhere was measured at 29 ms for
`netstat -ano` against 182 ms for `Get-NetTCPConnection`, and its output format
is the most fragile of the three, where a locale or version change silently
breaks the parser rather than failing loudly. A subprocess survives on exactly
one platform, so it is used there and nowhere else. The Windows call is
hand-declared as an `extern` because Zig's standard library does not ship it;
it lives in `iphlpapi.dll`, not `kernel32.dll`, so the shipped binary imports
`ntdll.dll`, `KERNEL32.dll` and `iphlpapi.dll`. The test binary additionally
imports `ws2_32.dll` to bind its own listener.
