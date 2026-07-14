# jobpool

## NAME

jobpool - a worker pool that owns each job's lifecycle: cancel a running job, pause the queue, cap one kind of work, watch every row change state

## SYNOPSIS

```tcl
package require jobpool

set pool [jobpool new 8 -init {source workers.tcl}]
$pool subscribe row-state {apply {{row st} {puts "$row -> $st"}}}
$pool set_worker_cap upload 1            ;# uploads serialise, the rest fan out
$pool enqueue job42 render render_one {file a.blend}
$pool cancel job42                       ;# reaches it even mid-render
```

## DESCRIPTION

Tcl's `tpool` runs your jobs and hands back a result. What it does not give you is anything between the post and the result: you cannot stop a job once it is running, you cannot hold the queue while a dialog is open, you cannot let ten renders run at once but only one upload, and you cannot follow a job through its stages without polling for the answer. `tpool::cancel` drops jobs still waiting in the queue and nothing else; there is one global worker count and no notion of a job kind.

jobpool is the layer that adds those. One shared pool of pre-spawned worker threads carries mixed work. Each row moves through a small state machine the pool owns. A running job is cancelled or paused cooperatively, through a shared-variable sentinel the worker polls at its own safe points, so no thread is ever killed from outside. A per-kind sub-cap sits inside the global cap, so one serial kind of work shares a pool with parallel kinds instead of needing a pool of its own. And every transition is an event a view subscribes to, so a treeview repaints from the pool instead of from a tangle of `thread::send` replies that may arrive after the row was cancelled.

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

A worker proc runs in a pool interpreter and is posted as `<worker> <row> <opts>`. Before the *-init* script runs, the pool sets three globals in the interpreter: `::main_tid` and `::dispatcher`, the thread and object a worker messages home to, and `::jobpool_tsv`, the shared-variable array a worker reads for its cancel and pause sentinels. A worker stays responsive to cancel and pause by checking that array between units of work, and reports its progress by calling the message methods below on `::dispatcher` across threads.

## THE MESSAGE SURFACE

A worker calls these on the pool object through `thread::send -async`; each runs back on the pool's own thread. A message that changes state is checked against the row's current state and dropped, with a diagnostic, when it does not fit, so a late message cannot revive a finished row.

**on_phase** *row name* / **on_progress** *row text*
: Informational: the job entered a named phase, or has freeform progress text. No state change.

**on_rate_limited** *row until* / **on_rate_limit_cleared** *row*
: The worker is now waiting on an external limit, or is running again.

**on_paused** *row* / **on_resumed** *row*
: The worker saw the pause sentinel and stopped at a safe point, or was released.

**on_done** *row* ?*result*? / **on_failed** *row reason* / **on_cancelled** *row*
: Terminal. `on_cancelled` follows the worker seeing the cancel sentinel.

A consumer whose workers send kinds of their own subclasses jobpool and adds the matching `on_<name>` methods; the inherited `_fire` and the `_expect`/`_expect_active` guards are the pieces to build them from.

## THE POOL API

**enqueue** *row kind worker opts*: register a row with its kind, the worker proc that runs it, and the opts dict the worker receives. **cancel** *row*: drop a queued row, or set the sentinel for a running one. **pause_row** / **resume_row** *row*, **pause_queue** / **resume_queue**: hold one row, or the whole queue. **requeue** *row*: send a terminal row back to queued for a retry. **prune_missing** *valid_rows*: drop rows a view refresh removed, keeping any that still hold a slot. **set_worker_cap** *kind cap*: the per-kind sub-cap. **set_pre_post_callback** *cmd*: a gate fired before each post, returning `abort` to cancel the row. **subscribe** *event cmd*. Read-only: **state**, **kind_of**, **count_by_kind**, **active_rows**, **queued_rows**, **all_rows**, **posted_count**, **is_queue_paused**, **jobs_cap**.

## THE EVENT STREAM

**subscribe** *event cmd* runs *cmd* with the event's arguments appended on every fire. `row-state` fires on every transition as `row new-state`; the finer `row-phase`, `row-progress`, `row-done`, `row-failed`, `row-paused`, `row-resumed`, `row-rate-limited`, and `row-rate-limit-cleared` carry each message on. A Tk view subscribes to `row-state` and repaints; a headless run subscribes to `row-done` and collects.

## NOTES

The sentinel is a `tsv` shared array private to each pool, so two pools in one process never cross each other's cancel and pause flags. Cancel and pause are cooperative by design: a worker that never checks the sentinel is never interrupted, which is the price of never killing a thread from underneath itself.

## REQUIREMENTS

Tcl 9, and the `Thread` package for the pool (`tpool::`). No Tk; the pool holds no widgets and a Tk view attaches through the event stream.

## KEYWORDS

thread pool, worker pool, job queue, cancellation, concurrency, state machine, rate limit, tpool, TclOO
