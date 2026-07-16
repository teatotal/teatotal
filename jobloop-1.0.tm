package require Tcl 9
package require TclOO
package require leash
package provide jobloop 1.0

# jobloop - an event-loop job pool that owns each job's lifecycle, not just
# its coroutine.
#
# A coroutine on the Tcl event loop already waits well: park on a
# fileevent or an after, yield, resume when the world answers. What bare
# coroutines do not give you is everything around the wait: no cap on how
# many run at once, no way to cancel one that is mid-wait, no queue to hold
# or pace, and no account of where each job stands short of instrumenting
# every body by hand. jobloop is that layer, built once: each job runs as
# a coroutine the pool owns, on the event loop the caller already has - one
# interpreter, no Thread package, no message marshalling. Jobs move through
# a small state machine; a running job is cancelled or paused cooperatively
# at its own safe points; per-kind caps, pacing floors, holds, and a
# lifetime launch cap shape which job launches next; and every transition
# is an event a subscriber follows.
#
#   set loop [jobloop new 8]
#   $loop subscribe job-done {apply {{job result} {puts "$job: $result"}}}
#   $loop set_kind_cap fetch 2             ;# two fetches at a time, rest fan out
#   $loop set_kind_pace fetch 400          ;# and >=400 ms between fetch launches
#   $loop enqueue job42 fetch {url http://example.com/feed}
#   $loop cancel job42                     ;# reaches it even mid-wait
#
# THE WORKERS
#
# A job's kind names the command that runs it, called as `<kind> <job>
# <opts>` inside a coroutine the pool owns, in the calling interpreter.
# register remaps a kind to any command prefix; an unregistered kind calls
# the command of its own name. A worker waits the loop's way: arm a
# fileevent or an after that resumes [info coroutine], then yield. A worker
# that blocks instead, in a bare vwait or a synchronous read, stalls every
# job in the process, which is the sign the work belongs in jobpool.
#
# THE WORKER VERBS (::jobloop::worker::*)
#
# A body picks up the verbs with one `namespace path ::jobloop::worker`
# line; each takes the job first. Every verb resolves its pool from
# [info coroutine], so the same body reports to whichever loop owns it.
#
# checkpoint job         the cancel and pause observation point. On cancel
#                        it reports the cancellation and unwinds the body;
#                        on pause it parks the coroutine (a yield) until
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
# cancel unwind (a JOBLOOP CANCEL errorcode) is trapped in RunJob. However
# a body ends, its slot is freed.
#
# CONSTRUCTION
#
#   jobloop new jobs ?-log cmd? ?-logger service?
#     jobs        the pool size: at most this many concurrent coroutines.
#     -log        a command prefix called with one string per dropped or
#                 out-of-order report (a diagnostic channel).
#     -logger     a logger(n) service name for the same (default "jobloop").
#
# There is no worker bootstrap: workers are commands in the calling
# interpreter, defined wherever the caller keeps them.
#
# THE STATE MACHINE
#
#   queued -> running -> done|failed|cancelled
#   running <-> paused           (user hold, observed at a checkpoint)
#   running <-> rate_limited     (worker waiting on an external limit)
#   queued  -> cancelled         (dropped before it ever launches)
#
# running, paused and rate_limited each hold one of the pool's slots;
# queued does not.
#
# THE REPORTING SURFACE (verb -> pool method)
#
#   on_phase on_progress on_rate_limited on_rate_limit_cleared
#   on_paused on_resumed on_done on_failed on_cancelled
#
# A report that changes state is checked against the job's current state
# and dropped, with a diagnostic, when it does not fit, so a stale report
# cannot revive a finished job. A consumer with reports of its own
# subclasses jobloop and adds the matching on_<name> methods; the inherited
# _fire and the _expect guards are the pieces to build them from.
#
# PACING, HOLDS, AND THE COUNT CAP
#
#   set_kind_pace kind ms   >=ms between successive launches of a kind; its
#                           jobs wait in the queue, other kinds launch
#                           around them. Paces launches, not completions.
#   hold_kind kind          stop launching a kind while its running jobs
#                           finish; the cap underneath is untouched. The
#                           first job held back fires kind-held once.
#   release_kind kind       drain a held kind; fires kind-released.
#   set_count_cap n         stop launching after n launches in the pool's
#                           lifetime, firing count-cap-reached once; 0 lifts.
#
# THE EVENT STREAM
#
#   subscribe <event> <cmd>    every fire of <event> calls cmd with the
#                              event's arguments appended.
#
# job-state fires on every transition (job, new-state); the finer events
# job-phase, job-progress, job-done, job-failed, job-paused, job-resumed,
# job-rate-limited, job-rate-limit-cleared carry each report on. queue-
# paused/queue-resumed track the whole-queue hold; kind-held/kind-released
# track a single kind; count-cap-reached fires when the spent budget first
# holds a job back.
#
# NOTES
#
# Cancel and pause are cooperative: a worker that never calls checkpoint is
# never interrupted, the price of never tearing a coroutine out of its own
# stack. destroy cancels the pool's pending timers (through leash) and
# deletes its coroutines; that reaping relies on the yield convention, and
# a coroutine suspended inside a nested vwait of its own cannot be deleted
# mid-wait. Cancel and drain such a job before destroying, or wait the
# loop's way.
#
# Written against Tcl 9. Copyright (c) 2025 Weiwu Zhang, MIT license.

# The worker vocabulary. Each verb resolves the owning pool from the
# process-global Owner dict, keyed by the running coroutine; _start sets
# that key before the coroutine is created, and RunJob clears it in its
# finally. The verbs are commands, not methods, so a body in the calling
# interpreter picks them up with `namespace path`.
namespace eval ::jobloop {
    variable Owner
    if {![info exists Owner]} { set Owner [dict create] }
}
namespace eval ::jobloop::worker {
    proc _pool {} { dict get $::jobloop::Owner [info coroutine] }
    proc checkpoint {job}          { [_pool] _checkpoint $job }
    proc phase {job name}          { [_pool] on_phase $job $name }
    proc progress {job text}       { [_pool] on_progress $job $text }
    proc rate_limited {job until}  { [_pool] on_rate_limited $job $until }
    proc rate_limit_cleared {job}  { [_pool] on_rate_limit_cleared $job }
    proc done {job {result {}}}    { [_pool] on_done $job $result }
    proc failed {job reason}       { [_pool] on_failed $job $reason }
}

oo::class create jobloop {
    mixin leash

    variable Jobs KindCap
    variable Queue JobState JobMeta
    variable QueuePaused
    variable LogCallback LogService PreLaunchCallback Subs
    variable Terminal Reg
    variable KindPace LastLaunch PaceTimer
    variable HeldKinds HeldAnnounced
    variable CountCap Launched CountAnnounced
    variable Coros CancelFlag PauseFlag Serial

    constructor {jobs args} {
        set Jobs             $jobs
        set KindCap          [dict create]
        set Queue            {}
        set JobState         [dict create]
        set JobMeta          [dict create]
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
        set Coros            [dict create]
        set CancelFlag       [dict create]
        set PauseFlag        [dict create]
        set Serial           0

        set LogCallback ""
        set LogService  jobloop
        foreach {opt val} $args {
            switch -- $opt {
                -log     { set LogCallback $val }
                -logger  { set LogService  $val }
                default  { error "jobloop: unknown option $opt" }
            }
        }
    }

    destructor {
        # leash (the mixin) has already cancelled the pool's timers and, in
        # deleting the instance namespace, reaps every coroutine armed there.
        # Drop this pool's keys from the shared Owner dict so a torn-down
        # pool leaves nothing behind. Collect the keys before unsetting, not
        # during the walk.
        set drop {}
        dict for {co owner} $::jobloop::Owner {
            if {$owner eq [self]} { lappend drop $co }
        }
        foreach co $drop { dict unset ::jobloop::Owner $co }
    }

    # ─── Subscription ────────────────────────────────────────────────
    method subscribe {event cb} { dict lappend Subs $event $cb }
    method subscribed {event} { return [dict exists $Subs $event] }
    method _fire {event args} {
        if {![dict exists $Subs $event]} return
        foreach cb [dict get $Subs $event] { {*}$cb {*}$args }
    }

    # set_pre_launch_callback - a synchronous admission gate fired just
    # before each launch, as `{*}$cb $job $kind`. "abort" cancels the job
    # before any coroutine runs; "defer" leaves it queued for a later
    # walk, which any enqueue, completion, release, resume, or pace
    # re-drain triggers; anything else admits it.
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
    # active_jobs - jobs holding a slot: launched, not yet terminal. Queued
    # jobs are not active; they have not launched.
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
    # cap. A job of this kind launches only while fewer than <cap> of its
    # kind are active. The default cap is Jobs (no extra limit).
    method set_kind_cap {kind cap} { dict set KindCap $kind $cap }

    # set_kind_pace - keep at least ms between successive launches of a
    # kind. Its jobs wait in the queue until the floor clears; other kinds
    # launch around them.
    method set_kind_pace {kind ms} { dict set KindPace $kind $ms }

    # set_count_cap - stop launching after n launches in the pool's
    # lifetime, firing count-cap-reached once, when the spent budget first
    # holds a job back. 0 lifts the cap. A fresh cap re-arms the announce.
    method set_count_cap {n} {
        set CountCap $n
        set CountAnnounced 0
        my _try_launch
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
        my _try_launch
    }

    method _active_count_for_kind {kind} {
        set n 0
        foreach job [my active_jobs] {
            if {[dict get $JobMeta $job kind] eq $kind} { incr n }
        }
        return $n
    }

    # ─── Mutators ────────────────────────────────────────────────────

    # register - remap a kind to a command prefix. An unregistered kind runs
    # the command of its own name.
    method register {kind cmdprefix} { dict set Reg $kind $cmdprefix }

    # enqueue - register a job. kind names the command that runs it and is
    # the axis the per-kind cap, pacing, and holds work on; opts is the dict
    # that command receives. -priority (an integer, default 0) orders the
    # queue high-first, first-in first-out within a level; the physical
    # controls still gate each launch.
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
        my _try_launch
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

    # cancel - a queued job drops before it launches; a running job gets the
    # cancel flag and unwinds at its next checkpoint. A paused job is resumed
    # straight into the post-pause cancel check.
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
        dict set CancelFlag $job 1
        if {$s eq "paused"} { my _resume_coro $job }
    }

    method pause_job {job} {
        if {![dict exists $JobState $job]} return
        if {[dict get $JobState $job] in $Terminal} return
        dict set PauseFlag $job 1
    }
    method resume_job {job} {
        if {![dict exists $JobState $job]} return
        set state [dict get $JobState $job]
        catch {dict unset PauseFlag $job}
        if {$state eq "paused"} { my _resume_coro $job }
    }
    method pause_queue {} { set QueuePaused 1; my _fire queue-paused }
    method resume_queue {} {
        set QueuePaused 0
        my _fire queue-resumed
        my _try_launch
    }

    # prune_missing - drop every job whose key is not in $valid_jobs. Active
    # jobs (running/paused/rate_limited) keep their state: they own a slot
    # and will reach a terminal report on their own. Only terminal or
    # not-yet-launched jobs are collectable.
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
            catch {dict unset JobMeta $job}
            catch {dict unset CancelFlag $job}
            catch {dict unset PauseFlag $job}
            set idx [lsearch -exact $Queue $job]
            if {$idx >= 0} { set Queue [lreplace $Queue $idx $idx] }
        }
        return [llength $dropped]
    }

    # requeue - move a terminal job back to queued for a retry, clearing any
    # prior flag.
    method requeue {job} {
        if {![dict exists $JobState $job]} return
        if {[dict get $JobState $job] ni $Terminal} return
        catch {dict unset CancelFlag $job}
        catch {dict unset PauseFlag $job}
        dict set JobMeta $job started_at ""
        my _set_state $job queued
        my _queue_insert $job
        my _try_launch
    }

    # ─── Worker verb → pool reports ──────────────────────────────────

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
        my _try_launch
    }
    method on_failed {job reason} {
        if {![my _expect $job failed {running paused rate_limited}]} return
        my _set_state $job failed
        my _fire job-failed $job $reason
        my _try_launch
    }
    method on_cancelled {job} {
        # rate_limited is cancellable too: a job waiting out an external
        # limit still checkpoints, and its cancel must free the slot rather
        # than strand the job in rate_limited with the report refused.
        if {![my _expect $job cancelled {running paused rate_limited}]} return
        my _set_state $job cancelled
        my _try_launch
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

    # ─── Coroutine mechanics ─────────────────────────────────────────

    # _checkpoint - the pool side of the checkpoint verb, running in the
    # job's own coroutine. A pending cancel reports the cancellation and
    # raises JOBLOOP CANCEL, which RunJob traps; a pending pause reports it,
    # parks the coroutine on a yield, and on resume re-checks cancel first,
    # so cancelling a paused job takes at the park. Exported so the verb, a
    # plain command outside the object, can reach it.
    method _checkpoint {job} {
        if {[dict exists $CancelFlag $job]} {
            my on_cancelled $job
            return -code error -errorcode {JOBLOOP CANCEL} cancelled
        }
        if {[dict exists $PauseFlag $job]} {
            my on_paused $job
            if {[dict get $JobState $job] ne "paused"} return
            yield
            if {[dict exists $CancelFlag $job]} {
                my on_cancelled $job
                return -code error -errorcode {JOBLOOP CANCEL} cancelled
            }
            my on_resumed $job
        }
    }
    export _checkpoint

    method _resume_coro {job} {
        if {![dict exists $Coros $job]} return
        set co [dict get $Coros $job]
        if {![llength [info commands $co]]} return
        # A subscriber that resumes or cancels the job from within the report
        # that fired inside this very coroutine would call a coroutine already
        # on the stack. Defer to the next loop turn, by when it has parked.
        if {[info coroutine] eq $co} {
            my later 0 [list [namespace which my] _resume_coro $job]
            return
        }
        $co
    }

    # _start - fired by the launch's 0 ms timer, off the queue walk so no
    # worker code runs inline. A cancel arriving in the gap reports the
    # cancellation instead of starting the body.
    method _start {job} {
        if {![dict exists $JobState $job]} return
        if {[dict get $JobState $job] ne "running"} return
        if {[dict exists $CancelFlag $job]} {
            my on_cancelled $job
            return
        }
        set name co[incr Serial]
        set co [info object namespace [self]]::$name
        # Key Owner before creating the coroutine: the body runs to its first
        # yield the moment `coro` creates it, and may call a verb at once.
        dict set ::jobloop::Owner $co [self]
        dict set Coros $job $co
        my coro $name [namespace which my] RunJob $job
    }

    # RunJob - the coroutine body. It runs the worker command and frees the
    # slot however that ends: a bare return reports done empty, an uncaught
    # error reports failed, the cancel unwind is trapped. The finally clears
    # the coroutine's Owner key and the Coros entry.
    method RunJob {job} {
        set co [info coroutine]
        try {
            set meta [dict get $JobMeta $job]
            set kind [dict get $meta kind]
            set opts [dict get $meta opts]
            set cmdprefix [expr {[dict exists $Reg $kind]
                                 ? [dict get $Reg $kind] : $kind}]
            try {
                {*}$cmdprefix $job $opts
                # The fallback done fires only for a body that reported none
                # of its own, so a body that already reported draws no
                # "dropping" diagnostic from the refused second report.
                if {[my state $job] ni $Terminal} { my on_done $job }
            } trap {JOBLOOP CANCEL} {} {
            } on error {msg} {
                my on_failed $job $msg
            }
        } finally {
            catch {dict unset ::jobloop::Owner $co}
            catch {dict unset Coros $job}
        }
    }

    # ─── Internals ───────────────────────────────────────────────────

    # _try_launch - walk the queue in order, launching any job that clears
    # every admission control. State flips to running at launch time, before
    # the coroutine starts, so the cap math reads straight from the state map
    # and there is no queued/running gap to race; the body itself is armed by
    # a 0 ms timer so the walk never runs worker code inline. The controls
    # fold in per job: the lifetime count cap first (nothing more launches
    # once it is hit), then the global cap (stop and keep the tail), a held
    # kind (announce once, keep queued, scan on so other kinds launch), the
    # per-kind cap, the pacing floor (track the soonest wait and arm one
    # coalesced re-drain), and the admission gate.
    method _try_launch {} {
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
            if {$PreLaunchCallback ne ""} {
                set verdict ""
                catch {set verdict [{*}$PreLaunchCallback $job $kind]}
                if {$verdict eq "abort"} {
                    my _set_state $job cancelled
                    continue
                } elseif {$verdict eq "defer"} {
                    lappend new_queue $job
                    continue
                }
            }
            dict set LastLaunch $kind [clock milliseconds]
            incr Launched
            dict set JobMeta $job started_at [clock milliseconds]
            my _set_state $job running
            my later 0 [list [namespace which my] _start $job]
        }
        set Queue $new_queue
        if {$soonest ne ""} {
            set PaceTimer [my later $soonest \
                [list [namespace which my] _try_launch]]
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
    # _expect_active - an informational report is allowed in any non-terminal
    # state.
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
        if {$to in $Terminal} {
            catch {dict unset CancelFlag $job}
            catch {dict unset PauseFlag $job}
        }
        my _fire job-state $job $to
    }
    method _log {msg} {
        catch {${LogService}::warn $msg}
        if {$LogCallback ne ""} { {*}$LogCallback "jobloop: $msg" }
    }
}
