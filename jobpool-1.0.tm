package require Tcl 9
package require TclOO
package require Thread
package require jobloop
package provide jobpool 1.0

# jobpool - a worker pool that owns each job's lifecycle, not just its
# thread.
#
# tpool runs your jobs and hands back a result; nothing between the post
# and the result is yours to steer. You cannot cancel a job that is
# already running, hold the queue on demand, keep one kind of job to a
# single worker while the rest fan out, or watch a job move through its
# states without polling. jobpool is that missing layer: one shared pool
# of pre-spawned worker threads, a per-job state machine (queued, running,
# paused, rate_limited, and the terminals done/failed/cancelled),
# cooperative cancel and pause of a *running* job through a sentinel the
# worker polls, a global concurrency cap with a per-kind sub-cap inside it,
# per-kind pacing floors and holds, a lifetime launch cap, and an event
# stream a subscriber follows instead of decoding thread messages by hand.
#
#   set pool [jobpool new 8 -init {source workers.tcl}]
#   $pool subscribe job-state {apply {{job st} {puts "$job -> $st"}}}
#   $pool set_kind_cap heavy 1             ;# one heavy job at a time, rest fan out
#   $pool set_kind_pace heavy 400          ;# and >=400 ms between heavy launches
#   $pool enqueue job42 heavy {input data-42}
#   $pool cancel job42                     ;# reaches it even mid-run
#
# jobpool is the worker-thread runtime of ::jobloop::engine, the lifecycle
# engine the jobloop module publishes: the queue, the state machine and its
# guards, the admission controls, and the event stream live there, written
# once for both twins. This module answers the engine's runtime seam with
# threads: Launch posts the body to the tpool, the cancel and pause signals
# travel as tsv sentinels the worker polls, and Reap reclaims each finished
# job's tpool result record.
#
# THE POOL AND ITS WORKERS
#
# Workers live in the thread pool's own interpreters, seeded once from the
# -init script. Before that script runs the pool seeds each interpreter
# with the worker verbs (::jobpool::worker::*) and the plumbing they need:
# ::main_tid and ::pool, so a verb can message home, and ::jobpool_tsv, the
# shared-variable array a worker polls for its cancel and pause sentinels.
# A job's kind names the proc that runs it, defined by -init and called as
# `<kind> <job> <opts>`; register remaps a kind to any command prefix. The
# body reports and stays cancellable through the verbs, picked up with one
# `namespace path ::jobpool::worker` line.
#
# CONSTRUCTION
#
#   jobpool new jobs ?-init script? ?-log cmd? ?-logger service?
#     jobs        the pool size: this many worker threads, pre-spawned.
#     -init       the worker bootstrap, run once per worker interpreter.
#     -log        a command prefix called with one string for each
#                 dropped/out-of-order report (a diagnostic channel).
#     -logger     a logger(n) service name for the same diagnostics
#                 (default "jobpool").
#
# Pre-spawning is not a tuning choice. With a lazily grown pool the Thread
# package keeps one worker for the pool's whole life no matter how many
# jobs arrive, and everything after the first runs in series; equal min
# and max worker counts are the only shape that gives real parallelism.
#
# THE STATE MACHINE
#
#   queued -> running -> done|failed|cancelled
#   running <-> paused           (user hold, via the pause sentinel)
#   running <-> rate_limited     (worker waiting on an external limit)
#   queued  -> cancelled         (dropped before it ever posts)
#
# running, paused and rate_limited each hold a worker slot; queued does
# not. A cancel on a queued job drops it in place; on a running job it
# sets the sentinel and waits for the worker to notice and report back.
#
# THE WORKER VERBS (::jobpool::worker::*, seeded into each interpreter)
#
# checkpoint job         the cancel and pause observation point. On cancel
#                        it reports the cancellation and unwinds the body;
#                        on pause it parks (polling the sentinel) until
#                        resumed, then re-checks cancel, so cancelling a
#                        paused job takes at the park.
# phase job name         informational: entered a named phase
# progress job text      informational: freeform progress text
# rate_limited job until  running -> rate_limited (holds the slot)
# rate_limit_cleared job  rate_limited -> running
# done job ?result?      terminal: -> done, result rides the event
# failed job reason      terminal: -> failed, reason rides the event
#
# A body that returns without a terminal verb is reported done with an
# empty result; an uncaught error is reported failed with its message; the
# cancel unwind is trapped in the injected `run` wrapper. However a body
# ends, its slot is freed.
#
# THE REPORTING SURFACE (worker verb -> pool method, via thread::send -async)
#
# Each verb lands on a matching pool method, run on the pool's own thread.
# State-changing reports are validated against the job's current state and
# dropped (with a diagnostic) when they do not fit, so a report that arrives
# after the job was cancelled cannot resurrect it.
#
#   on_phase on_progress on_rate_limited on_rate_limit_cleared
#   on_paused on_resumed on_done on_failed on_cancelled
#
# A consumer with reports of its own subclasses jobpool and adds the
# matching on_<name> methods; the inherited _fire and the _expect guards
# are there to build them from.
#
# PACING, HOLDS, AND THE COUNT CAP
#
#   set_kind_pace kind ms   >=ms between successive launches of a kind;
#                           its jobs wait in the queue, other kinds launch
#                           around them. Paces launches, not completions.
#   hold_kind kind          stop launching a kind while its running jobs
#                           finish; the cap underneath is untouched. The
#                           first job held back fires kind-held once.
#   release_kind kind       drain a held kind; fires kind-released.
#   set_count_cap n         stop launching after n launches in the pool's
#                           lifetime, firing count-cap-reached once; 0 lifts.
#
# THE EVENT STREAM (pool -> subscribers, on the pool's thread)
#
#   subscribe <event> <cmd>    every fire of <event> calls cmd with the
#                              event's arguments appended.
#
# job-state fires on every transition (job, new-state); the finer events
# job-phase, job-progress, job-done, job-failed, job-paused, job-resumed,
# job-rate-limited, job-rate-limit-cleared carry each report on. queue-
# paused/queue-resumed track the whole-queue hold; kind-held/kind-released
# track a single kind; count-cap-reached fires when the spent budget first
# holds a job back. Either, both, or neither may be listening; the pool fires regardless.
#
# Written against Tcl 9. Copyright (c) 2025 Weiwu Zhang, MIT license.

oo::class create jobpool {
    superclass ::jobloop::engine

    variable JobMeta Reg LogName
    variable Pool PostId Sentinels

    constructor {jobs args} {
        set LogName jobpool
        set PostId  [dict create]

        set init ""
        set rest {}
        foreach {opt val} $args {
            if {$opt eq "-init"} { set init $val } else { lappend rest $opt $val }
        }
        next $jobs {*}$rest

        # The sentinel channel: a thread shared-variable array private to
        # this pool, so two pools in one process never cross cancel/pause
        # flags. The worker reads it under the ::jobpool_tsv name the
        # initcmd injects below.
        set Sentinels ::jobpool::s[my Serial]

        set me  [self]
        set tid [thread::id]
        # The preamble runs before the user's -init, so a body sourced there
        # can `namespace path ::jobpool::worker` and pick up the verbs.
        set initcmd [string cat \
            "set ::main_tid [list $tid]\n" \
            "set ::pool [list $me]\n" \
            "set ::jobpool_tsv [list $Sentinels]\n" \
            [my _preamble] "\n" \
            $init]
        set Pool [tpool::create \
            -minworkers $jobs \
            -maxworkers $jobs \
            -idletime   60 \
            -initcmd    $initcmd]
    }

    destructor {
        # leash (the engine's mixin) has already cancelled the pacing timer
        # and chained here; release the thread pool. Running jobs finish on
        # their own threads and their late reports land nowhere.
        if {[info exists Pool]} { catch {tpool::release $Pool} }
    }

    # A per-interp serial, so each pool's sentinel array has its own name.
    method Serial {} {
        if {![info exists ::jobpool_seq]} { set ::jobpool_seq 0 }
        return [incr ::jobpool_seq]
    }

    # The worker-side vocabulary, seeded into every worker interpreter. Each
    # verb marshals home with thread::send -async; checkpoint reads the tsv
    # sentinels. run wraps a body so it frees its slot however it ends: a
    # bare return reports done empty, an error reports failed, and the
    # cancel unwind (a JOBPOOL CANCEL errorcode raised by checkpoint) is
    # swallowed after on_cancelled has already gone home.
    method _preamble {} {
        return {
            namespace eval ::jobpool::worker {}
            proc ::jobpool::worker::_home {name args} {
                thread::send -async $::main_tid [list $::pool $name {*}$args]
            }
            proc ::jobpool::worker::_cancelled {job} {
                tsv::exists $::jobpool_tsv $job.cancel
            }
            proc ::jobpool::worker::_paused {job} {
                tsv::exists $::jobpool_tsv $job.pause
            }
            proc ::jobpool::worker::checkpoint {job} {
                if {[_cancelled $job]} {
                    _home on_cancelled $job
                    return -code error -errorcode {JOBPOOL CANCEL} cancelled
                }
                if {[_paused $job]} {
                    _home on_paused $job
                    while {[_paused $job] && ![_cancelled $job]} { after 20 }
                    if {[_cancelled $job]} {
                        _home on_cancelled $job
                        return -code error -errorcode {JOBPOOL CANCEL} cancelled
                    }
                    _home on_resumed $job
                }
            }
            proc ::jobpool::worker::phase {job name} { _home on_phase $job $name }
            proc ::jobpool::worker::progress {job text} { _home on_progress $job $text }
            proc ::jobpool::worker::rate_limited {job until} { _home on_rate_limited $job $until }
            proc ::jobpool::worker::rate_limit_cleared {job} { _home on_rate_limit_cleared $job }
            proc ::jobpool::worker::done {job {result {}}} {
                set ::jobpool::worker::Reported($job) 1
                _home on_done $job $result
            }
            proc ::jobpool::worker::failed {job reason} {
                set ::jobpool::worker::Reported($job) 1
                _home on_failed $job $reason
            }
            proc ::jobpool::worker::run {cmdprefix job opts} {
                try {
                    {*}$cmdprefix $job $opts
                    # The fallback done fires only for a body that reported
                    # none of its own; the Reported flag it set otherwise
                    # spares the pool a refused second report and its
                    # "dropping" diagnostic. The cancel unwind takes the trap
                    # below, never this fallback.
                    if {![info exists ::jobpool::worker::Reported($job)]} { done $job }
                } trap {JOBPOOL CANCEL} {} {
                } on error {msg} {
                    failed $job $msg
                } finally {
                    catch {unset ::jobpool::worker::Reported($job)}
                }
            }
        }
    }

    # ─── The runtime seam, over worker threads ───────────────────────

    # Launch - post the body to the thread pool, keeping the post id so
    # Reap can retrieve the result record after the terminal report.
    method Launch {job} {
        set meta [dict get $JobMeta $job]
        set kind [dict get $meta kind]
        set cmdprefix [expr {[dict exists $Reg $kind]
                             ? [dict get $Reg $kind] : $kind}]
        dict set PostId $job [tpool::post -nowait $Pool \
            [list ::jobpool::worker::run $cmdprefix $job [dict get $meta opts]]]
    }
    method SignalCancel {job state} { tsv::set $Sentinels $job.cancel 1 }
    method SignalPause {job} { tsv::set $Sentinels $job.pause 1 }
    method SignalResume {job state} { catch {tsv::unset $Sentinels $job.pause} }
    method ClearSignals {job} {
        catch {tsv::unset $Sentinels $job.cancel}
        catch {tsv::unset $Sentinels $job.pause}
    }

    # Reap - retrieve and discard the worker's tpool result so the thread
    # pool does not keep one result record per finished job for the pool's
    # whole life. The real result rode home on the worker's report
    # (thread::send); the run has returned or is about to, so the get does
    # not block meaningfully.
    method Reap {job} {
        if {[dict exists $PostId $job]} {
            catch {tpool::get $Pool [dict get $PostId $job]}
            dict unset PostId $job
        }
    }
}
