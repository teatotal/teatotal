package require Tcl 9
package require TclOO
package require Thread
package require leash
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
#                 dropped/out-of-order message (a diagnostic channel).
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
# THE MESSAGE SURFACE (worker thread -> pool, via thread::send -async)
#
# Each verb lands on a matching pool method, run on the pool's own thread.
# State-changing messages are validated against the job's current state and
# dropped (with a diagnostic) when they do not fit, so a message that
# arrives after the job was cancelled cannot resurrect it.
#
#   on_phase on_progress on_rate_limited on_rate_limit_cleared
#   on_paused on_resumed on_done on_failed on_cancelled
#
# A consumer with its own message kinds subclasses jobpool and adds the
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
# job-rate-limited, job-rate-limit-cleared carry each message on. queue-
# paused/queue-resumed track the whole-queue hold; kind-held/kind-released
# track a single kind; count-cap-reached fires when the launch budget runs
# out. Either, both, or neither may be listening; the pool fires regardless.
#
# Written against Tcl 9. Copyright (c) 2025 Weiwu Zhang, MIT license.

oo::class create jobpool {
    mixin leash

    variable Pool Jobs KindCap
    variable Queue JobState JobMeta PostId
    variable QueuePaused
    variable LogCallback LogService PreLaunchCallback Subs Sentinels
    variable Terminal Reg
    variable KindPace LastLaunch PaceTimer
    variable HeldKinds HeldAnnounced
    variable CountCap Launched CountAnnounced

    constructor {jobs args} {
        set Jobs             $jobs
        set KindCap          [dict create]
        set Queue            {}
        set JobState         [dict create]
        set JobMeta          [dict create]
        set PostId           [dict create]
        set QueuePaused      0
        set PreLaunchCallback ""
        set Subs             [dict create]
        set Terminal         {done failed cancelled}
        set Reg              [dict create]
        set KindPace         [dict create]
        set LastLaunch       [dict create]
        set PaceTimer        ""
        set HeldKinds        [dict create]
        set HeldAnnounced    [dict create]
        set CountCap         0
        set Launched         0
        set CountAnnounced   0

        set LogCallback ""
        set LogService  jobpool
        set init        ""
        foreach {opt val} $args {
            switch -- $opt {
                -log     { set LogCallback $val }
                -init    { set init        $val }
                -logger  { set LogService  $val }
                default  { error "jobpool: unknown option $opt" }
            }
        }

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
        # leash (the mixin) has already cancelled the pacing timer and
        # chained here; release the thread pool. Running jobs finish on
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
            proc ::jobpool::worker::done {job {result {}}} { _home on_done $job $result }
            proc ::jobpool::worker::failed {job reason} { _home on_failed $job $reason }
            proc ::jobpool::worker::run {cmdprefix job opts} {
                try {
                    {*}$cmdprefix $job $opts
                    done $job
                } trap {JOBPOOL CANCEL} {} {
                } on error {msg} {
                    failed $job $msg
                }
            }
        }
    }

    # ─── Subscription ────────────────────────────────────────────────
    method subscribe {event cb} { dict lappend Subs $event $cb }
    method subscribed {event} { return [dict exists $Subs $event] }
    method _fire {event args} {
        if {![dict exists $Subs $event]} return
        foreach cb [dict get $Subs $event] { {*}$cb {*}$args }
    }

    # set_pre_launch_callback - a synchronous admission gate fired just
    # before each launch, as `{*}$cb $job $kind $idx $total`. "abort" drops
    # the job before any worker runs; "defer" leaves it queued for a later
    # walk, which any enqueue, completion, release, resume, or pace re-drain
    # triggers; anything else admits it. idx is the job's 1-based position
    # among those enqueued and total the count so far, so an admitter can
    # pace by position.
    method set_pre_launch_callback {cb} { set PreLaunchCallback $cb }

    # ─── Accessors ───────────────────────────────────────────────────
    method state {job} {
        if {[dict exists $JobState $job]} { return [dict get $JobState $job] }
        return ""
    }
    method kind_of {job} {
        if {[dict exists $JobMeta $job]} { return [dict get $JobMeta $job kind] }
        return ""
    }
    method count_by_kind {kind state} {
        set n 0
        dict for {job meta} $JobMeta {
            if {[dict get $meta kind] ne $kind} continue
            if {[dict get $JobState $job] ne $state} continue
            incr n
        }
        return $n
    }
    # active_jobs - jobs holding a worker slot: posted, not yet terminal.
    # Queued jobs are not active; they have not posted.
    method active_jobs {} {
        set out {}
        dict for {job state} $JobState {
            if {$state in {running paused rate_limited}} { lappend out $job }
        }
        return $out
    }
    method queued_jobs {} {
        set out {}
        dict for {job state} $JobState {
            if {$state eq "queued"} { lappend out $job }
        }
        return $out
    }
    method all_jobs {} { return [dict keys $JobState] }
    method is_queue_paused {} { return $QueuePaused }
    method jobs_cap {} { return $Jobs }
    method is_kind_held {kind} { return [dict exists $HeldKinds $kind] }
    method launched_count {} { return $Launched }

    # set_kind_cap - a per-kind concurrency sub-cap inside the global Jobs
    # cap. A job of this kind posts only while fewer than <cap> of its kind
    # are active. The default cap is Jobs (no extra limit). This is what
    # lets one serial kind share a pool with parallel ones without a second
    # pool.
    method set_kind_cap {kind cap} { dict set KindCap $kind $cap }

    # set_kind_pace - keep at least ms between successive launches of a
    # kind. Its jobs wait in the queue until the floor clears; other kinds
    # launch around them.
    method set_kind_pace {kind ms} { dict set KindPace $kind $ms }

    # set_count_cap - stop launching after n launches in the pool's
    # lifetime, firing count-cap-reached once when the budget runs out. 0
    # lifts the cap. A fresh cap re-arms the one-shot announce.
    method set_count_cap {n} {
        set CountCap $n
        set CountAnnounced 0
        my _try_post_next
    }

    # hold_kind - stop a kind from launching while its running jobs finish
    # undisturbed. The cap underneath is untouched. release_kind brings it
    # back and drains what piled up.
    method hold_kind {kind} {
        dict set HeldKinds $kind 1
        catch {dict unset HeldAnnounced $kind}
    }
    method release_kind {kind} {
        if {![dict exists $HeldKinds $kind]} return
        dict unset HeldKinds $kind
        catch {dict unset HeldAnnounced $kind}
        my _fire kind-released $kind
        my _try_post_next
    }

    method _active_count_for_kind {kind} {
        set n 0
        foreach job [my active_jobs] {
            if {[dict get $JobMeta $job kind] eq $kind} { incr n }
        }
        return $n
    }

    # ─── Mutators ────────────────────────────────────────────────────

    # register - remap a kind to a command prefix in the worker
    # interpreters. An unregistered kind runs the command of its own name.
    method register {kind cmdprefix} { dict set Reg $kind $cmdprefix }

    # enqueue - register a job. kind names the proc that runs it and is the
    # axis the per-kind cap, pacing, and holds work on; opts is the dict
    # that proc receives. -priority (an integer, default 0) orders the queue
    # high-first, first-in first-out within a level; the physical controls
    # still gate each launch.
    method enqueue {job kind opts args} {
        if {[dict exists $JobState $job]} {
            my _log "enqueue: job $job already present (state [dict get $JobState $job]); ignoring"
            return
        }
        set priority 0
        foreach {opt val} $args {
            switch -- $opt {
                -priority { set priority $val }
                default   { error "enqueue: unknown option $opt" }
            }
        }
        if {![string is integer -strict $priority]} {
            error "enqueue: -priority must be an integer, got '$priority'"
        }
        dict set JobState $job queued
        dict set JobMeta  $job [dict create \
            kind       $kind \
            opts       $opts \
            priority   $priority \
            posted_at  [clock milliseconds] \
            started_at ""]
        my _queue_insert $job
        my _fire job-state $job queued
        my _try_post_next
    }

    # _queue_insert - place a job in the queue by priority then arrival: a
    # higher priority sits ahead, equal priorities keep first-in first-out.
    # The walk reads the queue in this order, so priority shapes which job
    # the physical controls weigh first, not whether they apply.
    method _queue_insert {job} {
        set p [dict get $JobMeta $job priority]
        set at [llength $Queue]
        for {set i 0} {$i < [llength $Queue]} {incr i} {
            if {[dict get $JobMeta [lindex $Queue $i] priority] < $p} {
                set at $i
                break
            }
        }
        set Queue [linsert $Queue $at $job]
    }

    # cancel - a queued job drops before it posts; a running job gets the
    # cancel sentinel and reports back when the worker next checks. A paused
    # job's pause loop exits on the sentinel, into the post-pause check.
    method cancel {job} {
        if {![dict exists $JobState $job]} return
        set s [dict get $JobState $job]
        if {$s eq "queued"} {
            set idx [lsearch -exact $Queue $job]
            if {$idx >= 0} { set Queue [lreplace $Queue $idx $idx] }
            my _set_state $job cancelled
            return
        }
        if {$s in $Terminal} return
        tsv::set $Sentinels $job.cancel 1
    }

    method pause_job {job} {
        if {![dict exists $JobState $job]} return
        if {[dict get $JobState $job] in $Terminal} return
        tsv::set $Sentinels $job.pause 1
    }
    method resume_job {job} {
        if {![dict exists $JobState $job]} return
        catch {tsv::unset $Sentinels $job.pause}
    }
    method pause_queue {} { set QueuePaused 1; my _fire queue-paused }
    method resume_queue {} {
        set QueuePaused 0
        my _fire queue-resumed
        my _try_post_next
    }

    # prune_missing - drop every job whose key is not in $valid_jobs. A
    # caller that recomputes the set of jobs it still wants uses this to
    # shed the rest in one call. Active jobs (running/paused/rate_limited)
    # keep their state: they own a slot and will reach a terminal message on
    # their own. Only terminal or not-yet-posted jobs are collectable.
    method prune_missing {valid_jobs} {
        set valid [dict create]
        foreach r $valid_jobs { dict set valid $r 1 }
        set dropped {}
        dict for {job state} $JobState {
            if {[dict exists $valid $job]} continue
            if {$state in {running paused rate_limited}} continue
            lappend dropped $job
        }
        foreach job $dropped {
            dict unset JobState $job
            catch {dict unset JobMeta  $job}
            catch {dict unset PostId $job}
            set idx [lsearch -exact $Queue $job]
            if {$idx >= 0} { set Queue [lreplace $Queue $idx $idx] }
            catch {tsv::unset $Sentinels $job.cancel}
            catch {tsv::unset $Sentinels $job.pause}
        }
        return [llength $dropped]
    }

    # requeue - move a terminal job back to queued for a retry, clearing any
    # prior sentinel.
    method requeue {job} {
        if {![dict exists $JobState $job]} return
        if {[dict get $JobState $job] ni $Terminal} return
        catch {tsv::unset $Sentinels $job.cancel}
        catch {tsv::unset $Sentinels $job.pause}
        dict set JobMeta $job started_at ""
        my _set_state $job queued
        my _queue_insert $job
        my _try_post_next
    }

    # ─── Worker → pool messages ──────────────────────────────────────

    method on_phase {job phase} {
        if {![my _expect_active $job phase]} return
        my _fire job-phase $job $phase
    }
    method on_progress {job text} {
        if {![my _expect_active $job progress]} return
        my _fire job-progress $job $text
    }
    method on_done {job {result {}}} {
        if {![my _expect $job done {running paused rate_limited}]} return
        my _set_state $job done
        my _fire job-done $job $result
        my _try_post_next
    }
    method on_failed {job reason} {
        if {![my _expect $job failed {running paused rate_limited}]} return
        my _set_state $job failed
        my _fire job-failed $job $reason
        my _try_post_next
    }
    method on_cancelled {job} {
        if {![my _expect $job cancelled {running paused}]} return
        my _set_state $job cancelled
        catch {tsv::unset $Sentinels $job.cancel}
        my _try_post_next
    }
    method on_rate_limited {job until} {
        if {![my _expect $job rate_limited running]} return
        my _set_state $job rate_limited
        my _fire job-rate-limited $job $until
    }
    method on_rate_limit_cleared {job} {
        if {![my _expect $job rate_limit_cleared rate_limited]} return
        my _set_state $job running
        my _fire job-rate-limit-cleared $job
    }
    method on_paused {job} {
        if {![my _expect $job paused running]} return
        my _set_state $job paused
        my _fire job-paused $job
    }
    method on_resumed {job} {
        if {![my _expect $job resumed paused]} return
        my _set_state $job running
        my _fire job-resumed $job
    }

    # ─── Internals ───────────────────────────────────────────────────

    # _try_post_next - walk the queue in order, posting any job that clears
    # every admission control. State flips to running at post time, not on a
    # later message, so the cap math reads straight from the state map and
    # there is no queued/running gap to race. The controls fold in per job:
    # the lifetime count cap first (nothing more launches once it is hit),
    # then the global cap (stop and keep the tail), a held kind (announce
    # once, keep queued, scan on so other kinds post), the per-kind cap, the
    # pacing floor (track the soonest wait and arm one coalesced re-drain),
    # and the admission gate. A job blocked by its kind alone stays queued
    # while the scan continues, so other kinds still post.
    method _try_post_next {} {
        if {$QueuePaused} return
        my forget $PaceTimer
        set PaceTimer ""
        set soonest ""
        set now [clock milliseconds]
        set new_queue {}
        set i 0
        set n [llength $Queue]
        while {$i < $n} {
            set job [lindex $Queue $i]
            incr i
            if {![dict exists $JobState $job]} continue
            if {[dict get $JobState $job] ne "queued"} continue

            if {$CountCap > 0 && $Launched >= $CountCap} {
                if {!$CountAnnounced} {
                    set CountAnnounced 1
                    my _fire count-cap-reached
                }
                lappend new_queue $job
                while {$i < $n} { lappend new_queue [lindex $Queue $i]; incr i }
                break
            }
            if {[llength [my active_jobs]] >= $Jobs} {
                lappend new_queue $job
                while {$i < $n} { lappend new_queue [lindex $Queue $i]; incr i }
                break
            }
            set meta [dict get $JobMeta $job]
            set kind [dict get $meta kind]
            if {[dict exists $HeldKinds $kind]} {
                if {![dict exists $HeldAnnounced $kind]} {
                    dict set HeldAnnounced $kind 1
                    my _fire kind-held $kind
                }
                lappend new_queue $job
                continue
            }
            set kcap [expr {[dict exists $KindCap $kind]
                            ? [dict get $KindCap $kind] : $Jobs}]
            if {[my _active_count_for_kind $kind] >= $kcap} {
                lappend new_queue $job
                continue
            }
            if {[dict exists $KindPace $kind] && [dict exists $LastLaunch $kind]} {
                set wait [expr {[dict get $KindPace $kind]
                                - ($now - [dict get $LastLaunch $kind])}]
                if {$wait > 0} {
                    if {$soonest eq "" || $wait < $soonest} { set soonest $wait }
                    lappend new_queue $job
                    continue
                }
            }
            set opts [dict get $meta opts]
            if {$PreLaunchCallback ne ""} {
                set total [dict size $JobState]
                set idx 0
                dict for {r _} $JobState {
                    incr idx
                    if {$r eq $job} break
                }
                set verdict ""
                catch {set verdict [{*}$PreLaunchCallback $job $kind $idx $total]}
                if {$verdict eq "abort"} {
                    my _set_state $job cancelled
                    continue
                } elseif {$verdict eq "defer"} {
                    lappend new_queue $job
                    continue
                }
            }
            set cmdprefix [expr {[dict exists $Reg $kind]
                                 ? [dict get $Reg $kind] : $kind}]
            dict set LastLaunch $kind [clock milliseconds]
            incr Launched
            dict set JobMeta $job started_at [clock milliseconds]
            my _set_state $job running
            dict set PostId $job [tpool::post -nowait $Pool \
                [list ::jobpool::worker::run $cmdprefix $job $opts]]
        }
        set Queue $new_queue
        if {$soonest ne ""} {
            set PaceTimer [my later $soonest \
                [list [namespace which my] _try_post_next]]
        }
    }

    # _expect - the job's state must be one of allowed_from for this
    # transition; log and refuse otherwise.
    method _expect {job transition allowed_from} {
        if {![dict exists $JobState $job]} {
            my _log "$transition for unknown job $job; dropping"
            return 0
        }
        set cur [dict get $JobState $job]
        if {$cur ni $allowed_from} {
            my _log "$transition for job $job in state $cur (allowed: [join $allowed_from {, }]); dropping"
            return 0
        }
        return 1
    }
    # _expect_active - an informational message is allowed in any
    # non-terminal state.
    method _expect_active {job mtype} {
        if {![dict exists $JobState $job]} {
            my _log "$mtype for unknown job $job; dropping"
            return 0
        }
        if {[dict get $JobState $job] in $Terminal} {
            my _log "$mtype for job $job in terminal state [dict get $JobState $job]; dropping"
            return 0
        }
        return 1
    }
    method _set_state {job to} {
        dict set JobState $job $to
        my _fire job-state $job $to
    }
    method _log {msg} {
        catch {${LogService}::warn $msg}
        if {$LogCallback ne ""} { {*}$LogCallback "jobpool: $msg" }
    }
}
