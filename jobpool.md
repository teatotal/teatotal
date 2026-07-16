# jobpool

## NAME

jobpool - a worker pool that owns each job's lifecycle: cancel a running job, pace or hold a kind of work, watch every job change state

## SYNOPSIS

```tcl
package require jobpool

set pool [jobpool new 8 -init {source workers.tcl}]
$pool subscribe job-done {apply {{job result} {puts "$job: $result"}}}
$pool set_kind_cap heavy 1              ;# one heavy job at a time, the rest fan out
$pool set_kind_pace heavy 400           ;# and at least 400 ms between heavy launches
$pool enqueue job42 heavy {input data-42}
$pool cancel job42                       ;# reaches it even mid-run
```

## DESCRIPTION

Tcl's `tpool` runs your jobs and hands back a result. What it does not give you is anything between the post and the result: you cannot stop a job once it is running, you cannot hold the queue on demand, you cannot let ten jobs of one kind run at once but hold another to one, and you cannot follow a job through its stages without polling for the answer. `tpool::cancel` drops jobs still waiting in the queue and nothing else; there is one global worker count and no notion of a job kind.

jobpool is the layer that adds those. One shared pool of pre-spawned worker threads carries mixed work. Each job moves through a small state machine the pool owns. A running job is cancelled or paused cooperatively, through a shared-variable sentinel the worker polls at its own safe points, so no thread is ever killed from outside. Per-kind caps, pacing floors, and holds shape which job launches next, so one serial or metered kind of work shares a pool with parallel kinds instead of needing a pool of its own. And every transition is an event a subscriber follows, so a caller reads state from the pool instead of untangling `thread::send` replies that may arrive after the job was cancelled.

## THE STATE MACHINE

```
queued -> running -> done | failed | cancelled
running <-> paused          a user hold, observed at a checkpoint
running <-> rate_limited     a worker waiting on an external limit
queued  -> cancelled         dropped before it ever launches
```

`running`, `paused`, and `rate_limited` each hold a worker slot; `queued` does not. `rate_limited` is the state for a job that is alive but blocked on something outside the pool: a throttled endpoint, a quota that ran dry until it resets. The pool does not decide when that happens; a worker reports it and reports when it clears.

## CONSTRUCTION

**jobpool new** *jobs* ?*-init script*? ?*-log cmd*? ?*-logger service*?
: A pool of *jobs* worker threads, pre-spawned. *-init* is the bootstrap run once in each worker interpreter: it defines the worker procs and whatever they load. *-log* is a command prefix called with one string per dropped or out-of-order report; *-logger* names a `logger` service for the same, defaulting to `jobpool`.

Pre-spawning is not a tuning choice but a correctness one. A pool grown lazily from zero keeps a single worker for its whole life however many jobs arrive, and everything past the first runs in series; equal minimum and maximum worker counts are the only shape that yields real parallelism.

## THE WORKERS

A job's kind names the proc that runs it, defined in the *-init* script and called as `<kind> <job> <opts>` in a worker interpreter; **register** *kind cmdprefix* remaps a kind to any command prefix defined there. Before that script runs, the pool seeds the interpreter with the worker verbs below and the plumbing they need: the thread and object reports travel home to, and the shared-variable array carrying each job's cancel and pause sentinels. A whole worker, with its wait, its checkpoint, and its result:

```tcl
# in workers.tcl, sourced by -init into each worker interpreter
namespace path ::jobpool::worker

proc heavy {job opts} {
    set total 0
    foreach chunk [split [dict get $opts input] ,] {
        checkpoint $job                 ;# a cancel or pause lands here
        incr total [crunch $chunk]      ;# the blocking work threads exist for
        progress $job "$chunk in"
    }
    done $job $total                    ;# delivered as the job-done event
}
```

The caller collects by subscribing, as in the SYNOPSIS: `done` and `failed` deliver their payloads on `job-done` and `job-failed`, and the pool stores no results, so a collector subscribes before it enqueues.

## THE WORKER VERBS

The pool defines a worker-side vocabulary in `::jobpool::worker`: **checkpoint**, **phase**, **progress**, **rate_limited**, **rate_limit_cleared**, **done**, **failed**, each taking the job first. A worker body picks them up with one `namespace path` line, and that line names which twin the body reports to.

**checkpoint** *job* is the cancel and pause observation point, called between units of work. On cancel it reports the cancellation and unwinds the worker body; code after it does not run. On pause it parks until resumed, then re-checks cancel, so cancelling a paused job takes effect at the park rather than at some later checkpoint. The other verbs report: **phase** *job name* and **progress** *job text* are informational; **rate_limited** *job until* and **rate_limit_cleared** *job* move the job in and out of its waiting state; **done** *job ?result?* and **failed** *job reason* are terminal, and their payloads ride the matching events. In this module the verbs carry their reports home across threads and read the sentinel array; the worker sees none of that.

## THE REPORTING SURFACE

Each verb lands on a matching pool method, delivered by `thread::send -async` and run on the pool's own thread: **on_phase**, **on_progress**, **on_rate_limited**, **on_rate_limit_cleared**, **on_paused**, **on_resumed**, **on_done**, **on_failed**, **on_cancelled**. A report that changes state is checked against the job's current state and dropped, with a diagnostic, when it does not fit, so a stale report cannot revive a finished job. The terminal verbs are not the only door: a worker body that raises an uncaught error is reported as failed, the error message its reason, and a body that returns without calling a terminal verb is reported done with an empty result, so a slot is freed however the body ends. A consumer with reports of its own subclasses jobpool and adds the matching `on_<name>` methods; the inherited `_fire` and the `_expect`/`_expect_active` guards are the pieces to build them from.

## THE POOL API

**enqueue** *job kind opts* ?*-priority n*?: register a job; *kind* names the proc that runs it (and is the axis the caps, pacing, and holds work on), *opts* the dict that proc receives. *-priority* is an integer, default 0: a higher priority launches first, ties break first-in first-out, and the order still bows to every physical control, so a high job of a capped or held kind waits behind the control while lower jobs of other kinds launch around it. An id the pool already knows is dropped with a diagnostic, whatever its state; a job's record outlives its run, staying readable after it ends until requeued or pruned. **register** *kind cmdprefix*: remap a kind to a command prefix in the worker interpreters. **cancel** *job*: drop a queued job, or set the sentinel for a running one; a paused job is resumed into that check. **pause_job** / **resume_job** *job*, **pause_queue** / **resume_queue**: hold one job, or the whole queue. **requeue** *job*: send a terminal job back to queued for a retry. **prune_missing** *valid_jobs*: reconcile the pool against the set of jobs the caller still wants, dropping the rest in one call and keeping any that still hold a slot. **set_kind_cap** *kind cap*: the per-kind sub-cap. **set_pre_launch_callback** *cmd*: a gate fired before each launch, returning `abort` to cancel the job, `defer` to leave it queued, or anything else to admit it. A deferred job is not cancelled and holds no slot; it stays in the queue and is reconsidered on the next walk, which any enqueue, completion, hold release, resume, or pace re-drain triggers. **subscribe** *event cmd*, **subscribed** *event*. **destroy**: releases the thread pool; running jobs finish on their own threads, and their late reports land nowhere, so cancel and drain first when the results matter. Read-only: **state**, **kind_of**, **count_by_kind**, **active_jobs**, **queued_jobs**, **all_jobs**, **is_queue_paused**, **jobs_cap**, **is_kind_held**, **launched_count**.

## PACING, HOLDS, AND THE COUNT CAP

Three admission controls sit in front of the launch, on the same kind axis as the cap. **set_kind_pace** *kind ms* keeps at least *ms* between successive launches of a kind; jobs of that kind wait in the queue until the floor clears, and other kinds launch around them. It paces launches, not completions: a floor for anything that meters arrivals, an API quota, a device that needs settling time, a host you choose to visit gently. **hold_kind** *kind* sits on top of the cap and stops a kind from launching while its running jobs finish undisturbed; the cap underneath comes back unchanged when **release_kind** *kind* drains the kind. The first job held back fires `kind-held`, once per hold, so a supervisor learns when work starts piling up behind its own decision; `kind-released` fires on release. **set_count_cap** *n* stops launching after *n* launches in the pool's lifetime and fires `count-cap-reached` once, when the spent budget first holds a job back; `0` lifts the cap. **is_kind_held** and **launched_count** read them back.

## THE EVENT STREAM

**subscribe** *event cmd* runs *cmd* with the event's arguments appended on every fire. `job-state` fires on every transition as `job new-state`. The finer events carry each report's payload: `job-done` as `job result`, `job-failed` as `job reason`, `job-phase` as `job name`, `job-progress` as `job text`, `job-rate-limited` as `job until`, and `job-paused`, `job-resumed`, `job-rate-limit-cleared` as `job`. `queue-paused` and `queue-resumed` fire when the whole queue is paused or resumed; `kind-held` and `kind-released` when one kind is held or released; `count-cap-reached` when the spent budget first holds a job back. A batch run subscribes to `job-done` and collects; a supervisor subscribes to `job-state` and follows each transition. **subscribed** *event* tells whether an event has any listener.

## CHOOSING BETWEEN THE TWINS

jobpool and jobloop are one design over two runtimes: the same state machine, pool API, events, and worker verbs. jobpool runs each job in a pre-spawned worker thread. Reach for it when the work burns CPU or calls a blocking library that would freeze an event loop; it costs the `Thread` dependency and isolated worker interpreters seeded by `-init`. jobloop runs each job as a coroutine on the event loop you already have. Reach for it when the work is mostly waiting, on subprocess pipes, sockets, or timers: a thread would idle on a read, and the loop multiplexes many waits in one interpreter with no marshalling. A worker's reporting and cancellation code moves between the twins unchanged, one `namespace path` line naming which twin it reports to; its waits are rewritten to the runtime, blocking reads in jobpool, fileevent-and-yield in jobloop, and its definition moves between the `-init` script and the calling interpreter. Parallel CPU takes jobpool; concurrent I/O takes jobloop.

## NOTES

The sentinel is a `tsv` shared array private to each pool, so two pools in one process never cross each other's cancel and pause flags. Cancel and pause are cooperative by design: a worker that never calls `checkpoint` is never interrupted, which is the price of never killing a thread from underneath itself. Reports arrive as events on the pool's own thread, so a command-line driver with no event loop of its own collects by entering one, a `vwait` on a completion counter being the usual shape. A per-job deadline is one line away, `after $ms [list $pool cancel $job]`, and `deadman` from this shelf owns the harder case of a subprocess that must die with its whole tree.

## REQUIREMENTS

Tcl 9, the `Thread` package for the pool (`tpool::`), and `leash` from this shelf for the pacing timers. No Tk.

## KEYWORDS

thread pool, worker pool, job queue, cancellation, concurrency, pacing, state machine, rate limit, tpool, TclOO
