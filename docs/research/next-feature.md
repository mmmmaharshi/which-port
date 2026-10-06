# What to build next in which-port

**Recommendation: report the Occupier's command line — the argument vector the
process was started with — as a new column beside `PROCESS`.** Not the working
directory, not the start time, not JSON. The command line, because no tool in this
category prints it, because users demonstrably ask for it and then run a *second*
command to get it, because both platforms can supply it without elevation using
handles and files `which-port` already touches, and because `CONTEXT.md` has no word
for it at all. It is the smallest change that turns "something is on 8080" into "the
Vite dev server I forgot about, not the Docker proxy".

Claims below are marked **verified** (read from a primary source, URL inline) or
**inferred** (my reasoning from those sources).

---

## 1. What comparable tools do

Read from each tool's own man page or source.

**`netstat -ano` (Windows).** Proto, Local Address, Foreign Address, State, PID.
**Verified** by running it here: `TCP 0.0.0.0:135 0.0.0.0:0 LISTENING 1484`. Stops at
the PID — not even a process name. (`netstat` on Linux with `-p` gives a PID/name
pair, e.g. `21219/unbound`: <https://man7.org/linux/man-pages/man8/netstat.8.html>.)

**`Get-NetTCPConnection`.** Documented parameters include `-OwningProcess` and
`-LocalPort`; the object carries `OwningProcess` as a bare integer. **Verified**:
<https://learn.microsoft.com/en-us/powershell/module/netTCPip/get-nettcpconnection>.
Two PowerShell issues requesting the thing `which-port` already does — show the
process name alongside the port — were closed because the cmdlet belongs to the
NetTCPIP module, not the PowerShell team:
<https://github.com/PowerShell/PowerShell/issues/8436> ("just add one more parameter
like -showprocessname") and <https://github.com/PowerShell/PowerShell/issues/13013>.

**`ss -ltnp`.** Prints `users:(("python3",pid=12345,fd=6))` — name, PID, fd.
**Verified** from source: `ss` builds its user table by walking `/proc/<pid>/fd` for
`socket:[<inode>]` links (`user_ent_hash_build_task`, `misc/ss.c` lines 797–940,
<https://github.com/iproute2/iproute2/blob/main/misc/ss.c>), and the *name* comes
from `/proc/<pid>/stat` via `fscanf(fp, "%*d (%[^)])", name)` — field 2, `comm`,
capped at `TASK_COMM_LEN` (16) characters **verified**
(<https://man7.org/linux/man-pages/man5/proc_pid_stat.5.html>). So `ss` reports a
truncated name and no arguments. It also has `-K/--kill`, which this tool has
correctly refused.

**`lsof -i :PORT -sTCP:LISTEN`.** `COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE
NAME`. `COMMAND` is the process name, truncated to nine characters in practice — a
widely-hit annoyance, e.g. `GoogleTal` for `GoogleTalkPlugin` in
<https://stackoverflow.com/questions/44339712/port-80-on-my-mac-interpreting-results>.
`USER` is the owning account. No argv. `lsof` gained `-F` field output and, in
4.99.7, `-J`/`-j` for JSON and JSON Lines — **verified**
<https://github.com/lsof-org/lsof/releases/tag/4.99.7>, PR #353.

**`sockstat -l -p 22` (FreeBSD).** `USER COMMAND PID FD PROTO LOCAL ADDRESS FOREIGN
ADDRESS` — **verified** <https://man.freebsd.org/cgi/man.cgi?query=sockstat&sektion=1>.
The only one of the seven reporting the owning user; also has `--libxo json`. No argv.

**Purpose-built port tools.** The category is crowded and each adds a different
non-socket fact on top of `lsof`. `ports` (Go) sells "project context, working
directory, parent process, uptime, and caffeinate status that `lsof` doesn't give you"
— **verified** <https://github.com/erdemylmaz/ports-cli>. `port-whisperer` sells "full
process tree, repository path, git branch, memory usage" — **verified**
<https://github.com/aradotso/trending-skills/blob/main/skills/port-whisperer-cli/SKILL.md>.
`procx` and `killport` add `--json` and kill-by-port. None of them can answer on
Windows without shelling out, and none prints the argv *as the answer*.

**Not one of the seven prints the argument vector.**

---

## 2. What users actually ask for

An issue is a request someone made and someone else triaged, which makes this the
strongest evidence here.

**create-react-app #441, "Guess what app is already running in port 3000"** —
<https://github.com/facebook/create-react-app/issues/441>. The requester wanted the
*name of the app*, not a PID: "Otherwise the next step is going to be to google how
to figure out what is running on a port, which is a bit annoying and we can solve for
the user."

The maintainer who shipped it wrote out the recipe that is still the de facto answer
to this question, and it is two commands:

```
> lsof -P | grep TCP | grep :3000
node      36663 vjeux   22u    IPv6 0x3c581a030a2e6b0e47   0t0     TCP *:3000 (LISTEN)
> ps -o command -p 36663
COMMAND
node /Users/vjeux/random/test/node_modules/react-scripts/scripts/start.js
```

`lsof` gives the PID; `ps` gives the thing actually wanted. The merged PR **#816,
"add logging of existing default port process on start"**
(<https://github.com/facebook/create-react-app/pull/816>) landed as
`packages/react-dev-utils/getProcessForPort.js`, now readable at
<https://github.com/facebook/create-react-app/blob/main/packages/react-dev-utils/getProcessForPort.js>.
It calls `lsof -i:<port> -P -t -sTCP:LISTEN` for the PID, then `ps -o command -p <pid>`
for the command line, then `lsof -p <pid> | awk '$4=="cwd"'` for the working
directory. Three subprocesses, and the middle one exists *solely* because the socket
tool could not supply it. That file is the gap, stated as working code.

**gatsby #569**, "Log which process is using port when there's a conflict"
(<https://github.com/gatsbyjs/gatsby/issues/569>), is the same request against a
different codebase, citing CRA PR #816. Two projects, one underlying ask.

**webpack-dev-server #2187**
(<https://github.com/webpack/webpack-dev-server/issues/2187>): a dev server that
"was running for a while, but it jammed and occupied the port and needed to kill the
process". The real question is *which of the several node processes I have running is
the stale one*, which `node.exe` cannot answer.

**"Address already in use" but nothing holds the port** is the other recurring theme
— <https://serverfault.com/questions/736429/some-other-process-running-on-port-80-blocks-nginx-to-start>,
<https://superuser.com/questions/11112/no-idea-what-is-listening-on-port-80-in-os-x>.
This is the `Free port` caveat in `CONTEXT.md`; see *Ruled out*.

---

## 3. What the platform can do that `which-port` does not use

**Windows.** The tool already opens every Occupier with
`OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` (`src/win.zig:46-47,147`). That exact
right suffices to read the command line via `NtQueryInformationProcess` class 60,
`ProcessCommandLineInformation` — required access `PROCESS_QUERY_LIMITED_INFORMATION`,
Windows 8.1+ **verified** <https://ntdoc.m417z.com/processinfoclass>. Microsoft warns
the classes are internal and recommends `LoadLibrary`/`GetProcAddress` **verified**
<https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntqueryinformationprocess>,
and Raymond Chen explains why there is no Win32 alternative: "Win32 doesn't expose a
process's command line to other processes" **verified**
<https://devblogs.microsoft.com/oldnewthing/20091125-00/>. The WMI escape hatch
(`Win32_Process.CommandLine` **verified**
<https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-process>) is slow
enough that gopsutil benchmarked WMI command-line retrieval at 36 ms per process
against 0.6 µs for `GetProcessTimes` **verified**
<https://github.com/shirou/gopsutil/issues/250>.

*Inference*: this is one call on a handle already open, so no new privilege boundary
crossed and the "never requires elevation" assertion in `win_test.zig` still holds.
It is a hand-declared `extern "ntdll"` beside the three already in `win.zig`, which is
the pattern ADR 0002 established.

Unused and unhelpful here: `TCP_TABLE_OWNER_PID_ALL` and `..._CONNECTIONS` exist
beside the `LISTENER` class in use today **verified**
<https://learn.microsoft.com/en-us/windows/win32/api/iprtrmib/ne-iprtrmib-tcp_table_class>,
<https://learn.microsoft.com/en-us/windows/win32/api/iphlpapi/nf-iphlpapi-getextendedtcptable>;
the `_MODULE_` variants return a module id, not a process identity.

**Linux.** `/proc/<pid>/cmdline` holds the full command line as NUL-separated strings
**verified** <https://man7.org/linux/man-pages/man5/proc_pid_cmdline.5.html>. Note the
contrast: `/proc/pid/exe`, which `lin.zig` already reads for the Path, is explicitly
gated by "a ptrace access mode `PTRACE_MODE_READ_FSCREDS` check" **verified**
<https://man7.org/linux/man-pages/man5/proc_pid_exe.5.html>, and the `cmdline` page
carries no such note. *Inference*: on a default non-`hidepid` mount the command line
will often be readable for processes whose image path is not, which would narrow the
`Withheld identity` case rather than widen it. Worth a fixture; worth not building a
promise on.

`INET_DIAG` / `sock_diag` netlink — what `ss` uses instead of procfs **verified**
<https://man7.org/linux/man-pages/man7/sock_diag.7.html> — yields `idiag_uid`,
`idiag_inode`, queue depths and timers, but **no PID**. It would not replace the
inode-to-PID walk in `lin.zig` and supplies no new facts; it would only be faster
than an approach that is already correct and already rootless.

---

## 4. Where the domain model has gaps

**Occupier** is "the process holding a listening socket on a given port". A *process*
is not what the user is identifying when three `node.exe` processes are running. The
tool can currently only answer at the granularity of the executable image.

**Path** is "the full filesystem path of the occupier's executable", `_Avoid_: location,
executable`. Genuinely useful — story 4 tells a real install from a shim — but it is
*not* what distinguishes `node server.js` from `node webpack-dev-server.js`. There is
no term for the argv, and no recorded reason why not.

**Occupancy** is deliberately binary ("occupied or free, never in between"), backed by
two recorded decisions in issue #1: "Scope is TCP Listening sockets only" and "Any
Non-Listening TCP state… They answer a different question." A considered position, not
an oversight. But it is a gap in the precise sense that the tool can say "port 8080 is
free" when the kernel will refuse the bind — and `Free port` has to apologise for it in
the glossary: "Free does not mean bindable; something else could be holding it in a
state this tool does not report." That sentence is the model admitting it cannot
represent a real state.

**Withheld identity** is well-modelled and rightly refuses to be "fixed" by demanding
elevation. The argv must fit inside that contract: a withheld argv is another `-`, not
an error.

The gap that matters most is the missing one. `Occupier` cannot say *which invocation*.

---

## What it would cost

**Data model.** One optional field on `Occupier` (`src/occupier.zig:18`):
`command_line: ?[]const u8`, beside `path`. `named()` gains a parameter; `withheld()`
sets it to `null` with its note unchanged. `lessThan` is unaffected — order is by pid
then address.

**Windows** (`src/win.zig`). One more `extern "ntdll"` declaration, the class-60
constant, and a size-probe-then-fetch pair in `describe()` beside the existing
`QueryFullProcessImageNameW` call — ~40 lines including the
`UNICODE_STRING`-header-then-inline-bytes parse. Reuses the handle already open at line
147, and follows the shape the file already sets with its three externs and its
`comptime` row-layout assertions (lines 165-169).

**Linux** (`src/lin.zig`). In `describe()` (line 148), read `<pid>/cmdline` with the
existing `readProcFile` helper (line 25 — which exists precisely because procfs lies
about its size) and replace NULs with spaces. ~15 lines. `attribute()` and the inode
join are untouched.

**Renderer** (`src/report.zig`). A fifth column; `table()` computes widths generically,
so a header entry and a cell function. The one real decision is placement: argv is
variable-length and dominates the row, so it belongs last after `PATH` — or `PROCESS`
should be dropped in favour of argv's first token. That is an interface change and
belongs in the ticket, not the code.

**Tests.** `scripts/test-all.ps1` needs no new step; the feature rides the existing
suites. `check-cli.ps1:81` asserts `'ADDRESS\s+PID\s+PROCESS\s+PATH'` and needs the new
header. `win_test.zig` and `lin_test.zig` each bind a listener in the test process and
know their own PID, so both can assert the reported argv contains the test binary's
name — failing for a real reason if the adapter is wrong, and only passing against a
live kernel. `check-vocabulary.ps1` runs mechanically against `_Avoid_` lists, so a new
glossary term needs its line written correctly.

**Size and risk.** ADR 0001 measures 490 KB stripped; this adds two externs, one struct
field and two small parsers, so tens of kilobytes at most. The subprocess machinery in
ADR 0002 is what to protect; this does not touch it. The Windows path depends on an
undocumented information class Microsoft says may change — mitigated by the treatment
`GetExtendedTcpTable` already gets (hand-declare, degrade to `-`), and by the fact that
a failed query is a withheld identity, never a wrong answer.

---

## Runner-ups

1. **`--json` / machine-readable output.** Convergent evidence: `lsof` shipped
   `-J`/`-j` in 4.99.7, `ss` has had `-j/--json` since iproute2 v4
   (<https://lists.openwall.net/netdev/2015/08/30/37>), `sockstat` has `--libxo json`.
   Loses because `which-port` already solved scripting the way it wanted to — the
   README's claim is that the exit code carries the answer so a script never parses
   text — and a second output shape contradicts the byte-identical and stable-column
   promises for a benefit nobody has asked of *this* tool.
2. **Start time / age.** Answers "the one I just started, or a three-day-old zombie?" —
   the real question in webpack-dev-server #2187 and pm2 #2050
   (<https://github.com/Unitech/pm2/issues/2050>, asking for a `port(s)` column beside
   `uptime`). Available both sides: `GetProcessTimes` on the existing handle
   **verified** <https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocesstimes>,
   `/proc/pid/stat` field 22 plus `/proc/uptime` on Linux. Loses because it needs a
   second notion of time (boot-relative ticks vs FILETIME) to refine the argv answer
   rather than replace it.
3. **Working directory.** Cheap on Linux (a `readlink` of `/proc/<pid>/cwd`) but not
   on Windows: it needs a PEB read, which needs `PROCESS_VM_READ`, a genuinely higher
   right than the `PROCESS_QUERY_LIMITED_INFORMATION` the tool deliberately holds.
   *Inference*: that breaks the no-elevation symmetry between the two shipped
   platforms, which is a worse trade than the fact it adds. Third for that reason, not
   for lower demand — CRA's implementation asks for cwd too.

---

## Ruled out, and why

- **Non-Listening blockers** (TIME_WAIT, CLOSE_WAIT, bound-but-inactive) — the "Free
  does not mean bindable" gap. Real and well-documented pain. But it is a recorded
  scope decision, stated twice in issue #1, and it has no good answer to give: a
  TIME_WAIT socket has *no process*, so there is no Occupier to print, and the fix is
  to wait or set `SO_REUSEADDR`, not to kill something. Serving it properly means a
  second domain concept (Blocker, or non-binary Occupancy) — a rewrite of the
  glossary's central term, not a feature. The data being cheap to get is what makes it
  tempting, and exactly why it needs its own decision and its own ticket.
- **UDP.** "Not a second filter but a second meaning, since a bound UDP socket is not a
  listening one" — issue #1's own words.
- **Killing the Occupier.** The tool answers; something else acts. Every kill-by-port
  tool in the category ships a `--yes` guard and a dry run, which is the shape of a
  different product.
- **All ports, or several ports at once.** "Multiple ports would each need their own
  table header, and a range would oblige the tool to sort and filter. Neither has been
  asked for." Nothing here contradicts it.
- **Ancestor processes.** Correctly refused: "Walking the parent chain is a guess about
  intent that is wrong under supervisors, init systems, and container shims." The argv
  does not walk the chain, which is the main reason to prefer it to the parent PID
  that `ports` and `port-whisperer` both sell.

---

## Verification status

**Verified from primary sources:** the `TCP_TABLE_CLASS` enumeration; `sock_diag(7)`'s
`inet_diag_msg` fields; `/proc/pid/{cmdline,exe,stat}` contents and permission notes;
`ss`'s procfs walk and `comm` truncation in `misc/ss.c`; `lsof` and `sockstat` column
sets; `ss` and `lsof` option sets from their own man pages; CRA #441, PR #816 and the
shipped `getProcessForPort.js`; gatsby #569; `ProcessCommandLineInformation`'s access
and version, from ntdoc and Microsoft's own caveat; Raymond Chen on Win32 not exposing
command lines; `Win32_Process.CommandLine`; gopsutil's WMI-vs-native benchmark;
`GetProcessTimes`; `netstat -ano`'s output, observed directly.

**Inferred:** that `cmdline` will often be readable where `exe` fails on Linux; that the
Windows change crosses no new privilege boundary; that argv column placement is a real
interface decision; that `cwd` would break platform symmetry on Windows.