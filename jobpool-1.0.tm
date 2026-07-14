package require Tcl 9
package require TclOO
package require Thread
package provide jobpool 1.0

# jobpool - a worker pool that owns each job's lifecycle, not just its
# thread.
#
# tpool runs your jobs and hands back a result; nothing between the post
# and the result is yours to steer. You cannot cancel a job that is
# already running, hold the queue on demand, keep one kind of job to a
# single worker while the rest fan out, or watch a job move through its
# states without polling. jobpool is that missing layer: one
# shared pool of pre-spawned worker threads, a per-job state machine
# (queued, running, paused, rate_limited, and the terminals done/failed/
# cancelled), cooperative cancel and pause of a *running* job through a
# sentinel the worker polls, a global concurrency cap with a per-kind
# sub-cap inside it, and an event stream a subscriber can follow instead
# of decoding thread messages by hand.
#
#   set pool [jobpool new 8 -init {source workers.tcl}]
#   $pool subscribe job-state {apply {{job st} {puts "$job -> $st"}}}
#   $pool set_kind_cap heavy 1             ;# one heavy job at a time, rest fan out
#   $pool enqueue job42 heavy {input data-42}
#   $pool cancel job42                     ;# reaches it even mid-run
#
# THE POOL AND ITS WORKERS
#
# Workers live in the thread pool's own interpreters, seeded once from the
# -init script. That script defines the procs jobs run under, one per kind
# (a job is posted as `<kind> <job> <opts>`) and whatever they need;
# jobpool adds three globals to it before it runs - ::main_tid and ::pool,
# so a worker can message home, and ::jobpool_tsv, the shared-variable
# array a worker polls for its cancel and pause sentinels. A worker
# reports progress and completion by calling back into the pool object
# across threads (the message surface below); it stays cancellable by
# checking the sentinels at its own safe points.
#
# CONSTRUCTION
#
#   jobpool new jobs ?-log cmd? ?-init script? ?-logger service?
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
# THE MESSAGE SURFACE (worker thread -> pool, via thread::send -async)
#
# A worker calls these on the pool object; each runs on the pool's own
# thread. State-changing messages are validated against the job's current
# state and dropped (with a diagnostic) when they do not fit, so a message
# that arrives after the job was cancelled cannot resurrect it.
#
#   on_phase job name          informational: entered a named phase
#   on_progress job text       informational: freeform progress text
#   on_rate_limited job until   running -> rate_limited (holds the slot)
#   on_rate_limit_cleared job   rate_limited -> running
#   on_paused job               running -> paused (worker saw the sentinel)
#   on_resumed job              paused -> running
#   on_done job ?result?        -> done
#   on_failed job reason        -> failed
#   on_cancelled job            -> cancelled (worker saw the sentinel)
#
# A consumer with its own message kinds subclasses jobpool and adds the
# matching on_<name> methods; the inherited _fire and the _expect guards
# are there to build them from.
#
# THE EVENT STREAM (pool -> subscribers, on the pool's thread)
#
#   subscribe <event> <cmd>    every fire of <event> calls cmd with the
#                              event's arguments appended.
#
# job-state fires on every transition (job, new-state); the finer events
# job-phase, job-progress, job-done, job-failed, job-paused, job-resumed,
# job-rate-limited, job-rate-limit-cleared carry each message on. A
# batch run subscribes to job-done and collects; a supervisor subscribes
# to job-state and follows each transition. Either, both, or neither may
# be listening; the pool fires regardless.
#
# Written against Tcl 9. Copyright (c) 2025 Weiwu Zhang, MIT license.

oo::class create jobpool {
    variable Pool Jobs KindCap
    variable Queue JobState JobMeta PostId
    variable QueuePaused
    variable LogCallback LogService PrePostCallback Subs Sentinels
    variable Terminal

    constructor {jobs args} {
        set Jobs            $jobs
        set KindCap       [dict create]
        set Queue           {}
        set JobState        [dict create]
        set JobMeta         [dict create]
        set PostId        [dict create]
        set QueuePaused     0
        set PrePostCallback ""
        set Subs            [dict create]
        set Terminal        {done failed cancelled}

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
        set initcmd "
            set ::main_tid [list $tid]
            set ::pool [list $me]
            set ::jobpool_tsv [list $Sentinels]
            $init
        "
        set Pool [tpool::create \
            -minworkers $jobs \
            -maxworkers $jobs \
            -idletime   60 \
            -initcmd    $initcmd]
    }

    destructor {
        if {[info exists Pool]} { catch {tpool::release $Pool} }
    }

    # A per-interp serial, so each pool's sentinel array has its own name.
    method Serial {} {
        if {![info exists ::jobpool_seq]} { set ::jobpool_seq 0 }
        return [incr ::jobpool_seq]
    }

    # ─── Subscription ────────────────────────────────────────────────
    method subscribe {event cb} { dict lappend Subs $event $cb }
    method subscribed {event} { return [dict exists $Subs $event] }
    method _fire {event args} {
        if {![dict exists $Subs $event]} return
        foreach cb [dict get $Subs $event] { {*}$cb {*}$args }
    }

    # set_pre_post_callback - a synchronous admission gate fired just
    # before each post, as `{*}$cb $job $kind $idx $total`. Return "abort"
    # to drop the job before any worker runs; anything else admits it.
    # idx is the job's 1-based position among those enqueued and total the
    # count so far, so an admitter can pace by position - one at a time,
    # or a batch at a time.
    method set_pre_post_callback {cb} { set PrePostCallback $cb }

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
    method posted_count {} { return [llength [my active_jobs]] }

    # set_kind_cap - a per-kind concurrency sub-cap inside the global Jobs
    # cap. A job of this kind posts only while fewer than <cap> of its kind
    # are active. The default cap is Jobs (no extra limit). This is what
    # lets one serial kind share a pool with parallel ones without a
    # second pool.
    method set_kind_cap {kind cap} { dict set KindCap $kind $cap }

    method _active_count_for_kind {kind} {
        set n 0
        foreach job [my active_jobs] {
            if {[dict get $JobMeta $job kind] eq $kind} { incr n }
        }
        return $n
    }

    # ─── Mutators ────────────────────────────────────────────────────

    # enqueue - register a job. kind names the proc that runs it (posted
    # as `kind job opts`) and is the axis the per-kind cap and the counts
    # work on; opts is the dict that proc receives.
    method enqueue {job kind opts} {
        if {[dict exists $JobState $job]} {
            my _log "enqueue: job $job already present (state [dict get $JobState $job]); ignoring"
            return
        }
        dict set JobState $job queued
        dict set JobMeta  $job [dict create \
            kind       $kind \
            opts       $opts \
            posted_at  [clock milliseconds] \
            started_at ""]
        lappend Queue $job
        my _fire job-state $job queued
        my _try_post_next
    }

    # cancel - a queued job drops before it posts; a running job gets the
    # cancel sentinel and reports back when the worker next checks.
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
    # keep their state: they own a slot and will reach a terminal message
    # on their own. Only terminal or not-yet-posted jobs are collectable.
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

    # requeue - move a terminal job back to queued for a retry, clearing
    # any prior sentinel.
    method requeue {job} {
        if {![dict exists $JobState $job]} return
        if {[dict get $JobState $job] ni $Terminal} return
        catch {tsv::unset $Sentinels $job.cancel}
        catch {tsv::unset $Sentinels $job.pause}
        dict set JobMeta $job started_at ""
        my _set_state $job queued
        lappend Queue $job
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

    # _try_post_next - walk the queue in order, posting any job that fits
    # both the global cap and its per-kind cap. State flips to running at
    # post time, not on a later message, so the cap math reads straight
    # from the state map and there is no queued/running gap to race. A
    # job blocked only by its per-kind cap stays queued while the scan
    # continues, so other kinds still post - per-kind FIFO under
    # contention, parallel across kinds.
    method _try_post_next {} {
        if {$QueuePaused} return
        set new_queue {}
        set i 0
        while {$i < [llength $Queue]} {
            set job [lindex $Queue $i]
            incr i
            if {![dict exists $JobState $job]} continue
            if {[dict get $JobState $job] ne "queued"} continue
            if {[llength [my active_jobs]] >= $Jobs} {
                lappend new_queue $job
                while {$i < [llength $Queue]} {
                    lappend new_queue [lindex $Queue $i]
                    incr i
                }
                break
            }
            set meta [dict get $JobMeta $job]
            set kind [dict get $meta kind]
            set kcap [expr {[dict exists $KindCap $kind]
                            ? [dict get $KindCap $kind] : $Jobs}]
            if {[my _active_count_for_kind $kind] >= $kcap} {
                lappend new_queue $job
                continue
            }
            set opts [dict get $meta opts]
            if {$PrePostCallback ne ""} {
                set total [dict size $JobState]
                set idx 0
                dict for {r _} $JobState {
                    incr idx
                    if {$r eq $job} break
                }
                set verdict ""
                catch {set verdict [{*}$PrePostCallback $job $kind $idx $total]}
                if {$verdict eq "abort"} {
                    my _set_state $job cancelled
                    continue
                }
            }
            dict set JobMeta $job started_at [clock milliseconds]
            my _set_state $job running
            dict set PostId $job \
                [tpool::post -nowait $Pool [list $kind $job $opts]]
        }
        set Queue $new_queue
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
