# deadman

## NAME

deadman - a subprocess watchdog: a command run in its own process group, the whole tree killed on stall, wall clock, or the caller's say-so

## SYNOPSIS

```tcl
package require deadman

# Synchronous: run, watch, return the verdict.
set res [deadman::run {sh -c make} -stall 60000 -wall 600000]
# -> cause exit   exit 0   signal {}   stdout {...}

# Asynchronous, with a quota check every 30s.
set h [deadman::run $argv -out run.log \
           -poll {30000 checkQuota} -done ranOut]
proc checkQuota {h} { if {[quotaGone]} { deadman::kill $h quota } }
proc ranOut {res} { ... }
```

## DESCRIPTION

A pipe to a child process reports what the child prints, not whether the child is still earning its keep. Left alone, a long-running child - a synthesis run, a regression binary, a build step - can go quiet and hold the pipe open forever (stall), grind on past any useful deadline (wall), or breach a bound only its caller knows how to measure (poll). `timeout(1)` covers one slice of this: it waits out its full wall even when the child went quiet in the first minute, reports exit 124 in place of the child's own exit, and signals the launcher alone, so forked children keep the license seat and the lock file. And killing is never one kill: a child that traps TERM needs escalation, and a pipe whose write end escaped into an orphan never delivers EOF at all. Each hazard has a known cure; scattering the cures across callers is how one is always missing.

deadman owns them all in one place. It launches the command in its own process group (setsid), streams stdout as it arrives, and watches with independent detectors: a stall clock that fires after N ms without a line of output, a wall clock that fires at N ms regardless, and a poll that hands control to the caller's own callback on a fixed cadence. Whichever detector fires, the whole process group gets TERM, a grace period, then KILL, then a forced close of the pipe, so neither a TERM-trapper nor an orphan holding the write end can wedge the run.

Without `-done` the call is synchronous: it runs the event loop internally and returns the result. With `-done cmd` it returns a handle at once and invokes `cmd` with the result appended when the child is reaped; a coroutine name works as `cmd`, so a coroutine-based scheduler resumes exactly where it yielded.

## COMMANDS

**deadman::run** *argv* ?*option value ...*?
: Run *argv* under the watchdog. Returns the result dict (sync) or a handle (with `-done`).

  `-stdin s`
  : Feed *s* to the child's stdin, encoded as UTF-8 bytes on a binary channel, written blocking so the whole input drains past the pipe buffer, then the write half is closed so the child sees EOF. Getting this sequence wrong truncates input at the first non-ASCII character or the pipe-buffer boundary, which is why the module owns it.

  `-out chan-or-file`
  : Tee stdout there as lines arrive (an open channel is used and left open; a path is opened line-buffered). Without `-out`, stdout is collected and returned in the result.

  `-err file-or-stdout`
  : Redirect the child's stderr to a file, or, as the word `stdout`, merge it into the watched stream (a file named stdout wants a `./` prefix). Absent, stderr passes through to the caller's own.

  `-line cmd`
  : Invoke *cmd* with each complete line. Serves progress meters and timestamped logs: `-line {apply {{l} {puts [clock format [clock seconds]]:$l}}}`.

  `-stall ms` / `-wall ms`
  : The two clocks, each off at 0 (the default). The stall clock is seeded at spawn and advances on every stdout line; a child is stalled when no line has arrived for the allowance. The wall clock is absolute.

  `-poll {ms cmd}`
  : Every *ms*, invoke *cmd* with the handle appended. The callback signals a breach by calling `deadman::kill` itself, naming its own cause; a return value carries no meaning, so a callback error is never mistaken for a verdict. On a shared tick the poll runs before the stall check, so a poll kill names its own cause instead of being masked as a stall.

  `-grace ms`
  : The escalation step, default 10000: TERM, *ms*, KILL, *ms*, force-close.

  `-done cmd`
  : Asynchronous completion, described above.

**deadman::kill** *h* ?*cause*?
: The caller's own breach: kill the tree now. *cause* (default `kill`) lands verbatim in the result. The first cause to land wins; later kills of the same run are no-ops.

**deadman::cancel** *h*
: Kill and tear down with no callbacks and no result. For the owner that is itself going away mid-run.

## THE RESULT

A dict of `cause`, `exit`, `signal`, and (without `-out`) `stdout`. `cause` is what deadman did: `exit` when the child died its own death, `stall`, `wall`, or the token a kill caller named. `exit` is the child's real exit code, mined from the reap rather than encoded in a sentinel like `timeout(1)`'s 124. `signal` names the signal when the child died by one, and stays separate so the exit code keeps its plain meaning. A run that needed the forced close forfeits the reap (exit 0, no signal); the recorded cause still says which detector fired.

## THE KILL

setsid makes the child a process-group lead, so `kill -TERM -- -<pid>` reaches the grandchildren; a positive-pid TERM behind it covers a host where setsid forks. The `--` escort matters more than it looks: `kill(1)` reads an unescorted `-<pid>` as `-1`, a broadcast to every process the caller's user owns - enough to end a desktop session with nothing in any log to say why. The escort is carried here, and the test suite keeps a bystander process alive across a group kill so it stays carried.

Without setsid on PATH (`gsetsid` is probed too, for hosts whose coreutils carry the g prefix), the same pipe path runs but kills reach the lead pid only; descendants the lead spawned survive as orphans. Detectors, causes, and exit codes are unaffected.

## LIMITS

The `-stdin` write is blocking and runs before the event loop starts, so a child that never reads its stdin while the input exceeds the pipe buffer holds the launch until it does; the wall cannot fire during that window. A lead process that closes its own stdout by hand and lives on delays the reap until it exits; with a stall or wall armed it is killed long before that matters. Progress means lines: a child that emits one endless unterminated line reads as silent to the stall clock.

## REQUIREMENTS

Tcl 9, no Tk, nothing beyond the core. Written and tested against Tcl 9 on Linux; whole-tree kills want setsid(1) (util-linux, or `gsetsid` from macOS coreutils), and degrade as described without it.

## KEYWORDS

subprocess, watchdog, timeout, stall, wall clock, process group, kill, exec, pipe
