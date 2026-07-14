# jobpool

## NAME

jobpool - a worker pool that owns each job's lifecycle: cancel a running job, pause the queue, cap one kind of work, watch every job change state

## SYNOPSIS

```tcl
package require jobpool

set pool [jobpool new 8 -init {source workers.tcl}]
$pool subscribe job-state {apply {{job st} {puts "$job -> $st"}}}
$pool set_kind_cap heavy 1              ;# one heavy job at a time, the rest fan out
$pool enqueue job42 heavy {input data-42}
$pool cancel job42                       ;# reaches it even mid-run
```

## DESCRIPTION

Tcl's `tpool` runs your jobs and hands back a result. What it does not give you is anything between the post and the result: you cannot stop a job once it is running, you cannot hold the queue on demand, you cannot let ten jobs of one kind run at once but hold another to one, and you cannot follow a job through its stages without polling for the answer. `tpool::cancel` drops jobs still waiting in the queue and nothing else; there is one global worker count and no notion of a job kind.

jobpool is the layer that adds those. One shared pool of pre-spawned worker threads carries mixed work. Each job moves through a small state machine the pool owns. A running job is cancelled or paused cooperatively, through a shared-variable sentinel the worker polls at its own safe points, so no thread is ever killed from outside. A per-kind sub-cap sits inside the global cap, so one serial kind of work shares a pool with parallel kinds instead of needing a pool of its own. And every transition is an event a subscriber follows, so a caller reads state from the pool instead of untangling `thread::send` replies that may arrive after the job was cancelled.

## THE STATE MACHINE

```
queued -> running -> done | failed | cancelled
running <-> paused          a user hold, through the pause sentinel
running <-> rate_limited     a worker waiting on an external limit
queued  -> cancelled         dropped before it ever posts
```

`running`, `paused`, and `rate_limited` each hold a worker slot; `queued` does not. `rate_limited` is the state for a job that is alive but blocked on something outside the pool: a throttled endpoint, a busy instrument, a license seat that is all checked out. The pool does not decide when that happens; a worker reports it and reports when it clears.

## CONSTRUCTION

**jobpool new** *jobs* ?*-init script*? ?*-log cmd*? ?*-logger service*?
: A pool of *jobs* worker threads, pre-spawned. *-init* is the bootstrap run once in each worker interpreter: it defines the worker procs and whatever they load. *-log* is a command prefix called with one string per dropped or out-of-order message; *-logger* names a `logger` service for the same, defaulting to `jobpool`.

Pre-spawning is not a tuning choice but a correctness one. A pool grown lazily from zero keeps a single worker for its whole life however many jobs arrive, and everything past the first runs in series; equal minimum and maximum worker counts are the only shape that yields real parallelism.

## THE WORKERS

A job's kind names the proc that runs it, defined in the *-init* script and posted as `<kind> <job> <opts>`. Before that script runs, the pool sets three globals in the interpreter: `::main_tid` and `::pool`, the thread and object a worker messages home to, and `::jobpool_tsv`, the shared-variable array a worker reads for its cancel and pause sentinels. A worker stays responsive to cancel and pause by checking that array between units of work, and reports its progress by calling the message methods below on `::pool` across threads.

## THE MESSAGE SURFACE

A worker calls these on the pool object through `thread::send -async`; each runs back on the pool's own thread. A message that changes state is checked against the job's current state and dropped, with a diagnostic, when it does not fit, so a late message cannot revive a finished job.

**on_phase** *job name* / **on_progress** *job text*
: Informational: the job entered a named phase, or has freeform progress text. No state change.

**on_rate_limited** *job until* / **on_rate_limit_cleared** *job*
: The worker is now waiting on an external limit, or is running again.

**on_paused** *job* / **on_resumed** *job*
: The worker saw the pause sentinel and stopped at a safe point, or was released.

**on_done** *job* ?*result*? / **on_failed** *job reason* / **on_cancelled** *job*
: Terminal. `on_cancelled` follows the worker seeing the cancel sentinel.

A consumer whose workers send kinds of their own subclasses jobpool and adds the matching `on_<name>` methods; the inherited `_fire` and the `_expect`/`_expect_active` guards are the pieces to build them from.

## THE POOL API

**enqueue** *job kind opts*: register a job; *kind* names the proc that runs it (and is the axis the cap and the counts work on), *opts* the dict that proc receives. **cancel** *job*: drop a queued job, or set the sentinel for a running one. **pause_job** / **resume_job** *job*, **pause_queue** / **resume_queue**: hold one job, or the whole queue. **requeue** *job*: send a terminal job back to queued for a retry. **prune_missing** *valid_jobs*: drop every job not in the given set (a caller shedding the jobs it no longer wants in one call), keeping any that still hold a slot. **set_kind_cap** *kind cap*: the per-kind sub-cap. **set_pre_post_callback** *cmd*: a gate fired before each post, returning `abort` to cancel the job. **subscribe** *event cmd*, **subscribed** *event*. Read-only: **state**, **kind_of**, **count_by_kind**, **active_jobs**, **queued_jobs**, **all_jobs**, **posted_count**, **is_queue_paused**, **jobs_cap**.

## THE EVENT STREAM

**subscribe** *event cmd* runs *cmd* with the event's arguments appended on every fire. `job-state` fires on every transition as `job new-state`; the finer `job-phase`, `job-progress`, `job-done`, `job-failed`, `job-paused`, `job-resumed`, `job-rate-limited`, and `job-rate-limit-cleared` carry each message on. `queue-paused` and `queue-resumed` fire when the whole queue is held or released. A batch run subscribes to `job-done` and collects; a supervisor subscribes to `job-state` and follows each transition. **subscribed** *event* tells whether an event has any listener.

## NOTES

The sentinel is a `tsv` shared array private to each pool, so two pools in one process never cross each other's cancel and pause flags. Cancel and pause are cooperative by design: a worker that never checks the sentinel is never interrupted, which is the price of never killing a thread from underneath itself.

## REQUIREMENTS

Tcl 9, and the `Thread` package for the pool (`tpool::`). No Tk.

## KEYWORDS

thread pool, worker pool, job queue, cancellation, concurrency, state machine, rate limit, tpool, TclOO
