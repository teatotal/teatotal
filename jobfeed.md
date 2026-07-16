# jobfeed

## NAME

jobfeed - the intake layer in front of a job pool: poll a work source, deduplicate what it hands back, deliver runs on demand, admit through a policy gate, and keep each outcome as history

## SYNOPSIS

```tcl
package require jobfeed

set pool [jobloop new 8]
set feed [jobfeed new [list $client fetch] runEmail $pool -interval 60]
$pool register email [list $feed jobWorker]
$feed subscribe job-done {apply {{event detail} {puts $detail}}}
$feed start                       ;# begin polling the source
$feed inject news 42 email        ;# deliver one now, ahead of the poll
```

## DESCRIPTION

A job pool (jobloop or jobpool from this shelf) runs work and reports each job's lifecycle. What it does not do is decide *which* work reaches it. Real work arrives from a source that has to be polled and may be slow or down. The same item can surface on two polls that overlap, and must not run twice at once. A person may deliver an item by hand and expect that delivery to be its own tracked run, not folded onto whatever the poll found. A policy may want to admit or defer each launch against a budget, a scope, or a paused line. And once a job ends, its outcome has to outlive it for a status view to read. Applications grow that intake one accessor at a time, and each grows it differently.

jobfeed is that layer, built once, on top of the pool the caller already has. It owns the poll heartbeat, the identity dedup, the delivered-run sequence, the admission gate wiring, and the live-and-finished bookkeeping. The pool underneath owns the concurrency, the pacing, and the cancellation. The two compose: a feed drives one pool, and every knob the pool already answers stays reachable.

## THE SOURCE

The source is a command prefix, invoked `{*}$source $callback`. It fetches the current work list however it likes, an async HTTP GET or a database read, and delivers it by calling `$callback` with one argument, the list of rows. Asking asynchronously is the point. A remote source must never stall the loop, so **pull** fires the source and returns, and the rows arrive later at **onWorkQueue**. An empty source (`""`) has nothing to fetch, so **pull** emits `pull-skip`. With polling on the heartbeat still re-arms, so **nextPoll** keeps publishing a deadline for an idle countdown and the skip repeats each interval until a source appears; a feed fed only by **inject** turns polling off (`-poll 0`).

A row is a dict. The default **onWorkQueue** reads `group`, `id`, and `poolkind` from each and enqueues it as polled work. A consumer whose rows carry more, such as a blocked flag, a scope to filter on, or rows that fan into a batch, overrides **onWorkQueue** and calls **enqueue** with its own extraction.

## IDENTITY, DEDUP, AND DELIVERY

Every work item has an identity, a *(group, id)* pair. *group* names a class of work, all the items that share a code, a queue, or a transition; *id* names one within it. A polled item keys on its identity alone, `group:id`, and **deduplicates**. If an item of that identity is already live, queued or running, the second is dropped, so a slow job still on the pool is never launched a second time from the next poll.

A **delivered** item is a new run every time. A per-identity sequence mints it its own key `group:id#N`, its own queue entry, and its own history row, so successive deliveries of one identity read apart on a board instead of folding together. **inject** delivers one. If the identity is already live it promotes a queued polled item in place, since the source's row and the person's ask are one item rather than two, or it answers *duplicate* for one already running. Otherwise it mints the delivered run. Delivered work enqueues at priority 1, ahead of polled work.

## THE WORKER AND THE DISPATCH

The pool runs each job through the feed's **jobWorker**, registered with the pool as `[list $feed jobWorker]` for whichever kinds the feed uses. jobWorker calls the caller's *dispatch* command prefix once and stashes the one result line it returns on the job. The pool's `job-done` then drives **reapCore**, which reads that line back. The dispatch is whatever runs the actual work and returns a result line, JSON by default so **classifyOutcome** can read its status. A dispatch that throws unwinds to the pool's failure path and is reaped as an error, its message the detail.

## THE GATE

The pool's pre-launch callback is wired to the feed's **gate**, so a launch the physical controls have cleared still passes one policy check. The physical controls are the caps, the pacing, and the holds. The default gate admits everything. A consumer overrides **gate** to return `defer` for an item its policy is not ready to launch, against a spent budget, an off-scope class, or a paused line. A deferred item stays queued, holds no slot, and is weighed again on the next walk, which any enqueue, completion, hold release, or **drain** triggers. It costs no launch. Waving a delivered item past the policy, since a person asked for it, is a convention rather than a guarantee jobfeed enforces: the base gate admits everything, so an override that defers polled work checks the item's `delivered` flag before its policy tests to keep that promise, as the demo's gate does.

## HISTORY AND THE READ MODEL

A live item sits in **Items** until it is reaped. On completion its outcome lands in **History**, a row of *group, id, status, detail, origin, ts* plus any extra fields the consumer's **classifyOutcome** returns, and stays there for a status view to read. *origin* is the provenance of a delivered item, which caller or surface delivered it (a label such as `PWA`, `CLI`, or `GUI`), and is empty for polled work. History grows unbounded; a long-lived feed caps it with **historyTrim** *keep*, which drops the oldest rows and keeps the newest *keep*. **workQueue** returns the last polled work list, **job** a snapshot of every live item, and **nextPoll** with **pollInterval** the heartbeat's deadline and period for an idle countdown.

## THE EVENT STREAM

**subscribe** *cmd* registers an observer, called with every emitted `event detail`; **unsubscribe** drops it. The feed emits `job-inject` when a delivery is announced, ahead of the pool's launch so an observer sees the injection before the start. It emits `job-start` when the worker begins, `job-done` when a job is reaped, `job-board` after a poll is taken in, `job-dup` for a delivery that met an item already live (running, or a prior delivery still queued), `config` when **setPoll** toggles the heartbeat, and `pull-skip` when a poll finds no source. A consumer with events of its own, a board refresh or a policy notice, emits them through the same **emit** seam, so its stream and the feed's are one.

## THE HOOKS

Eight methods carry the default behaviour and are the override points for a consumer's policy, the same subclass-and-override idiom jobloop's reporting surface uses:

**gate** *job kind*
: admission; return `defer`, `abort`, or admit.

**classifyOutcome** *item line*
: read a result line into `{status detail extra}`, where *extra* is a dict of additional fields merged into the history row (empty by default). The default parses a JSON object's status and detail and calls an unparseable line an error. Override to normalise a consumer's own status vocabulary and to carry extra history fields, such as a version stamp.

**onOutcome** *item status detail*
: act on a reaped outcome, feeding a breaker or keeping a tally. The default does nothing.

**reply** *to body*
: send a reply body to a parked request that rode on the item's reply token. The default does nothing; override to write the body back (e.g. to a socket).

**duplicateReply** *group id*
: the reply body for a delivery that met a live item (the duplicate case). The default is empty; override to author the body a caller's protocol expects.

**startLabel** *item*
: the leading word of the `job-start` notice.

**dispatchArgs** *item*
: the arguments jobWorker passes the dispatch. The default is `{poolkind group id}`.

**_sink** *event detail*
: a second home for every emitted event, a log or a health var. The default drops it.

A consumer subclasses jobfeed and overrides the ones its policy needs. The inherited **enqueue**, **workLive**, **promoteOrDup**, **reapCore**, and **emit** are the pieces to build the rest from.

## CHOOSING THE POOL

jobfeed drives one pool and cares only that it answers the shared pool API, which jobloop and jobpool both do: `enqueue`, `state`, `prune_missing`, `resume_queue`, `set_pre_launch_callback`, `subscribe`, `count_by_kind`, `active_jobs`. Reach for jobloop when the work is mostly waiting, on subprocess pipes, sockets, or timers, and for jobpool when it burns CPU or calls a blocking library. The feed above is the same either way. See jobloop(n) and jobpool(n) for that choice.

## NOTES

The pool is the caller's, not the feed's. A feed sets the pool's pre-launch callback and subscribes to its `job-done` and `job-failed`, so destroy or drain the feed before the pool: a pool that reaps a job after its feed is gone would fire `onPoolDone` into a deleted command. The feed's own destructor cancels its poll heartbeat and touches the pool no further, leaving the caller to destroy the pool it made. One feed drives one pool; a second feed on the same pool would answer the same `job-done`, so give each feed its own.

## REQUIREMENTS

Tcl 9, `TclOO`, `json` for the default outcome parse, and a pool object from this shelf (jobloop or jobpool). No Tk, no `Thread` of its own.

## KEYWORDS

work queue, intake, deduplication, polling, admission gate, job pool, history, delivery, TclOO
