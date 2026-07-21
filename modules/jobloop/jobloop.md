# jobloop

## NAME

jobloop - an event-loop job pool that owns each job's lifecycle: cancel a running job, pace or hold a kind of work, watch every job change state, without a thread anywhere

## SYNOPSIS

```tcl
package require jobloop

set loop [jobloop new 8]
$loop subscribe job-done {apply {{job result} {puts "$job: $result"}}}
$loop set_kind_cap fetch 2               ;# two fetches at a time, the rest fan out
$loop set_kind_pace fetch 400            ;# and at least 400 ms between fetch launches
$loop enqueue job42 fetch {url http://example.com/feed}
$loop cancel job42                       ;# reaches it even mid-wait
```

## DESCRIPTION

A coroutine on the Tcl event loop already waits well: park on a `fileevent` or an `after`, yield, resume when the world answers. What bare coroutines do not give you is everything around the wait: no cap on how many run at once, no way to cancel one that is mid-wait, no queue to hold or pace, and no account of where each job stands short of instrumenting every body by hand. Applications grow that scaffolding one `after` at a time, and each grows it differently.

jobloop is that layer, built once. Each job runs as a coroutine the pool owns, on the event loop the caller already has: one interpreter, no `Thread` package, no message marshalling. Jobs move through a small state machine; a running job is cancelled or paused cooperatively at its own safe points; per-kind caps, pacing floors, and holds shape which job launches next; and every transition is an event a subscriber follows.

## THE STATE MACHINE

```
queued -> running -> done | failed | cancelled
running <-> paused          a user hold, observed at a checkpoint
running <-> rate_limited     a worker waiting on an external limit
running <-> parked           a worker waiting out an external window, slot-free
queued  -> cancelled         dropped before it ever launches
```

`running`, `paused`, and `rate_limited` each hold one of the pool's slots; `queued` and `parked` do not. `rate_limited` is the state for a job that is alive but blocked on something outside the pool: a throttled endpoint, a quota that ran dry until it resets. The pool does not decide when that happens; a worker reports it and reports when it clears. `parked` is its slot-free sibling, for the window long enough that other work should use the slot meanwhile: the worker hands the slot back at the park, the next queued job launches, and the worker keeps its own wakeup until it reports back in. The terminal reports accept `parked`, so a cancel or an outcome discovered mid-park takes where the job stands.

## CONSTRUCTION

**jobloop new** *jobs* ?*-log cmd*? ?*-logger service*?
: A pool running at most *jobs* concurrent coroutines; the slot arithmetic is the same as jobpool's *jobs* worker threads, without the threads. *-log* is a command prefix called with one string per dropped or out-of-order report; *-logger* names a `logger` service for the same, defaulting to `jobloop`.

There is no worker bootstrap option: workers are commands in the calling interpreter, defined wherever the caller keeps them.

## THE WORKERS

A job's kind names the command that runs it, called as `<kind> <job> <opts>` inside a coroutine the pool owns. **register** *kind cmdprefix* remaps a kind to any command prefix (a method, a namespaced proc); unregistered kinds call the command of the same name.

A worker waits the loop's way: arm a `fileevent` or an `after` that resumes `[info coroutine]`, then `yield`. The pool never preempts a wait; it acts at the worker's next checkpoint. A worker that blocks instead, in a bare `vwait` or a synchronous read, stalls every job in the process, which is the sign that the work belongs in jobpool. A whole worker, with its wait, its checkpoint, and its result:

```tcl
namespace path ::jobloop::worker

proc fetch {job opts} {
    if {[catch {open |[list curl -s [dict get $opts url]] r} chan]} {
        failed $job $chan                       ;# delivered as the job-failed event
        return
    }
    fconfigure $chan -blocking 0
    fileevent $chan readable [info coroutine]   ;# resume me when bytes arrive
    set body ""
    while {![eof $chan]} {
        yield                                   ;# park; the loop runs everyone else
        checkpoint $job                         ;# a cancel or pause lands here
        append body [read $chan]
    }
    close $chan
    done $job [string length $body]             ;# delivered as the job-done event
}
```

The caller collects by subscribing, as in the SYNOPSIS: `done` and `failed` deliver their payloads on `job-done` and `job-failed`, and the pool stores no results, so a collector subscribes before it enqueues.

## THE WORKER VERBS

The pool defines a worker-side vocabulary in `::jobloop::worker`: **checkpoint**, **phase**, **progress**, **rate_limited**, **rate_limit_cleared**, **parked**, **unparked**, **self**, **done**, **failed**, each but `self` taking the job first. A worker body picks them up with one `namespace path` line, and that line names which twin the body reports to.

**checkpoint** *job* is the cancel and pause observation point, called between units of work. On cancel it reports the cancellation and unwinds the worker body; code after it does not run. On pause it parks the coroutine until resumed, then re-checks cancel, so cancelling a paused job takes effect at the park rather than at some later checkpoint. The other verbs report: **phase** *job name* and **progress** *job text* are informational; **rate_limited** *job until* and **rate_limit_cleared** *job* move the job in and out of its slot-holding wait; **parked** *job note* and **unparked** *job* move it in and out of the slot-free one, the note riding `job-parked` for whoever renders the wait. The pool never resumes a parked job: the worker keeps its own wakeup through the park and should keep calling `checkpoint` there, so a cancel lands. `unparked` re-takes a slot with no cap re-check, `rate_limit_cleared`'s immediacy: the job already earned its launch, and its kind may transiently exceed its cap until the surplus drains. **self** takes no job and answers with the calling coroutine's, `""` outside one, so a library the worker calls into can report to the job without the id threaded through every argument list on the way down. **done** *job ?result?* and **failed** *job reason* are terminal, and their payloads ride the matching events. In this module the verbs are direct calls on the pool and the pause park is a coroutine yield; the worker sees none of that.

## THE REPORTING SURFACE

Each verb lands on a matching pool method: **on_phase**, **on_progress**, **on_rate_limited**, **on_rate_limit_cleared**, **on_parked**, **on_unparked**, **on_paused**, **on_resumed**, **on_done**, **on_failed**, **on_cancelled**. A report that changes state is checked against the job's current state and dropped, with a diagnostic, when it does not fit, so a stale report cannot revive a finished job. The terminal verbs are not the only door: a worker body that raises an uncaught error is reported as failed, the error message its reason, and a body that returns without calling a terminal verb is reported done with an empty result, so a slot is freed however the body ends. A consumer with reports of its own subclasses jobloop and adds the matching `on_<name>` methods; the inherited `_fire` and the `_expect`/`_expect_active` guards are the pieces to build them from.

## THE POOL API

**enqueue** *job kind opts* ?*-priority n*?: register a job; *kind* names the command that runs it (and is the axis the caps, pacing, and holds work on), *opts* the dict that command receives. *-priority* is an integer, default 0: a higher priority launches first, ties break first-in first-out, and the order still bows to every physical control, so a high job of a capped or held kind waits behind the control while lower jobs of other kinds launch around it. An id the pool already knows is dropped with a diagnostic, whatever its state; a job's record outlives its run, staying readable after it ends until requeued or pruned. **register** *kind cmdprefix*: remap a kind to a command prefix. **cancel** *job*: drop a queued job, or flag a running one to unwind at its next checkpoint; a paused job is resumed into that check. **pause_job** / **resume_job** *job*, **pause_queue** / **resume_queue**: hold one job, or the whole queue. **requeue** *job*: send a terminal job back to queued for a retry. **prune_missing** *valid_jobs*: reconcile the pool against the set of jobs the caller still wants, dropping the rest in one call and keeping any whose body is live (a slot-holder, or a parked job whose coroutine still waits). **set_kind_cap** *kind cap*: the per-kind sub-cap. **set_pre_launch_callback** *cmd*: a gate fired before each launch as `{*}cmd job kind`, returning `abort` to cancel the job, `defer` to leave it queued, or anything else to admit it. A deferred job is not cancelled and holds no slot; it stays in the queue and is reconsidered on the next walk, which any enqueue, completion, hold release, resume, or pace re-drain triggers. **subscribe** *event cmd*, **subscribed** *event*. **destroy**: cancels the pool's pending timers and deletes its coroutines; see NOTES for what that asks of a worker mid-wait. Read-only: **state**, **kind_of**, **count_by_kind**, **active_jobs**, **queued_jobs**, **parked_jobs**, **all_jobs**, **is_queue_paused**, **jobs_cap**, **is_kind_held**, **launched_count**. `active_jobs` is the slot-holders; a parked job appears in `parked_jobs` instead, the read a supervisor bounds launch-blind dispatch on.

## PACING, HOLDS, AND THE COUNT CAP

Three admission controls sit in front of the launch, on the same kind axis as the cap. **set_kind_pace** *kind ms* keeps at least *ms* between successive launches of a kind; jobs of that kind wait in the queue until the floor clears, and other kinds launch around them. It paces launches, not completions: a floor for anything that meters arrivals, an API quota, a device that needs settling time, a host you choose to visit gently. **hold_kind** *kind* sits on top of the cap and stops a kind from launching while its running jobs finish undisturbed; the cap underneath comes back unchanged when **release_kind** *kind* drains the kind. The first job held back fires `kind-held`, once per hold, so a supervisor learns when work starts piling up behind its own decision; `kind-released` fires on release. **set_count_cap** *n* stops launching after *n* launches in the pool's lifetime and fires `count-cap-reached` once, when the spent budget first holds a job back; `0` lifts the cap. **is_kind_held** and **launched_count** read them back.

## THE EVENT STREAM

**subscribe** *event cmd* runs *cmd* with the event's arguments appended on every fire. `job-state` fires on every transition as `job new-state`. The finer events carry each report's payload: `job-done` as `job result`, `job-failed` as `job reason`, `job-phase` as `job name`, `job-progress` as `job text`, `job-rate-limited` as `job until`, `job-parked` as `job note`, and `job-paused`, `job-resumed`, `job-rate-limit-cleared`, `job-unparked` as `job`. `queue-paused` and `queue-resumed` fire when the whole queue is paused or resumed; `kind-held` and `kind-released` when one kind is held or released; `count-cap-reached` when the spent budget first holds a job back. A batch run subscribes to `job-done` and collects; a supervisor subscribes to `job-state` and follows each transition. **subscribed** *event* tells whether an event has any listener.

## CHOOSING BETWEEN THE TWINS

jobpool and jobloop are one design over two runtimes: the same state machine, pool API, events, and worker verbs. The sharing is literal: the queue, state machine, admission controls, and event stream live in one engine class, `::jobloop::engine`, which this module publishes and both twins subclass. jobpool runs each job in a pre-spawned worker thread. Reach for it when the work burns CPU or calls a blocking library that would freeze an event loop; it costs the `Thread` dependency and isolated worker interpreters seeded by `-init`. jobloop runs each job as a coroutine on the event loop you already have. Reach for it when the work is mostly waiting, on subprocess pipes, sockets, or timers: a thread would idle on a read, and the loop multiplexes many waits in one interpreter with no marshalling. A worker's reporting and cancellation code moves between the twins unchanged, one `namespace path` line naming which twin it reports to; its waits are rewritten to the runtime, blocking reads in jobpool, fileevent-and-yield in jobloop, and its definition moves between the `-init` script and the calling interpreter. Parallel CPU takes jobpool; concurrent I/O takes jobloop.

## NOTES

Cancel and pause are cooperative by design: a worker that never calls `checkpoint` is never interrupted, which is the price of never tearing a coroutine out of its own stack. A per-job deadline is one line away, `after $ms [list $loop cancel $job]`, and `deadman` from this shelf owns the harder case of a subprocess that must die with its whole tree. Destroying the pool cancels its pending timers and deletes its coroutines; that reaping relies on the yield convention above. A worker parked on its own `after` or `fileevent` is not reaped whole: deleting the coroutine leaves that callback armed, to fire later into a deleted name as a background error, and a `fileevent` so left also leaks its channel; a coroutine suspended inside a nested `vwait` of its own cannot be deleted mid-wait at all. Cancel and drain any job that is actively waiting before destroying the pool, or better, wait the loop's way.

## REQUIREMENTS

Tcl 9, and `leash` from this shelf for timer and coroutine ownership. No Tk, no `Thread`.

## KEYWORDS

event loop, coroutine, job queue, cancellation, cooperative scheduling, pacing, rate limit, fileevent, state machine, TclOO
