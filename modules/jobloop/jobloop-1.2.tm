package require Tcl 9
package require TclOO
package require leash
package provide jobloop 1.2

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
# THE ENGINE (::jobloop::engine)
#
# Everything below except the coroutines lives in ::jobloop::engine, the
# runtime-independent lifecycle engine this module publishes: the queue,
# the state machine and its guards, the admission controls, the event
# stream. jobloop is that engine run over coroutines. jobpool, its own
# module on this shelf, subclasses the same engine over worker threads. A
# runtime answers six methods: Launch starts an admitted job's body;
# SignalCancel, SignalPause, and SignalResume carry a flag to wherever the
# running body can observe it; ClearSignals retracts both flags when a job
# reaches a terminal state or is pruned; Reap (a no-op by default)
# reclaims any per-launch record after a terminal report.
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
# parked job note        running -> parked: the job frees its slot while it
#                        waits out an external window, and the note rides
#                        job-parked. The pool never resumes a parked job: the
#                        worker keeps its own wakeup through the park and
#                        should checkpoint through it, so a cancel lands.
# unparked job           parked -> running. The job re-takes a slot with no
#                        cap re-check, like rate_limit_cleared's return: a
#                        kind may transiently exceed its cap until the
#                        surplus drains, the price of never stranding a job
#                        whose window has ended.
# self                   the calling coroutine's job id, "" outside a job -
#                        so a library the worker calls into can report to the
#                        job without the id threaded through every argument
#                        list on the way down.
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
#   running <-> parked           (worker waiting out an external window,
#                                 slot handed back meanwhile)
#   queued  -> cancelled         (dropped before it ever launches)
#
# running, paused and rate_limited each hold one of the pool's slots;
# queued and parked do not. parked is rate_limited's slot-free sibling: a
# rate_limited job's wait is expected to be short or exclusive, so it keeps
# its slot; a parked job's window may be long and other work could use the
# slot meanwhile, so parking frees it and the next queued job launches. A
# parked job may finish where it stands: the terminal reports accept parked,
# so a cancel or an outcome discovered mid-park needs no detour through
# running.
#
# THE REPORTING SURFACE (verb -> pool method)
#
#   on_phase on_progress on_rate_limited on_rate_limit_cleared
#   on_parked on_unparked on_paused on_resumed on_done on_failed on_cancelled
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
# job-rate-limited, job-rate-limit-cleared, job-parked, job-unparked carry
# each report on. queue-
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
    proc parked {job note}         { [_pool] on_parked $job $note }
    proc unparked {job}            { [_pool] on_unparked $job }
    proc done {job {result {}}}    { [_pool] on_done $job $result }
    proc failed {job reason}       { [_pool] on_failed $job $reason }
    # self - the job id of the coroutine this call runs in, "" outside one:
    # the same Owner lookup every verb makes, followed by the pool's reverse
    # map from coroutine to job. A library the worker calls into finds its
    # job here instead of having the id threaded through every argument list.
    proc self {} {
        set co [info coroutine]
        if {$co eq "" || ![dict exists $::jobloop::Owner $co]} { return "" }
        return [[dict get $::jobloop::Owner $co] job_of $co]
    }
}

# ::jobloop::engine - the runtime-independent lifecycle engine (see THE
# ENGINE above). It owns every job's record and decides what launches next;
# a runtime subclass owns how a body runs and how a signal reaches it.
oo::class create ::jobloop::engine {
    mixin leash

    variable Jobs KindCap
    variable Queue JobState JobMeta
    variable QueuePaused
    variable LogCallback LogService LogName PreLaunchCallback Subs
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

        # The runtime leaf names itself (LogName) before chaining here; a
        # subclass that does not is named by its class.
        if {![info exists LogName]} {
            set LogName [namespace tail [info object class [self]]]
        }
        set LogCallback ""
        set LogService  $LogName
        foreach {opt val} $args {
            switch -- $opt {
                -log     { set LogCallback $val }
                -logger  { set LogService  $val }
                default  { error "$LogName: unknown option $opt" }
            }
        }
    }

    # ─── The runtime seam ────────────────────────────────────────────
    # Launch, SignalCancel, SignalPause, SignalResume, and ClearSignals
    # have no default: an engine without a runtime can neither start a body
    # nor reach one. Reap defaults to nothing; a runtime with per-launch
    # records to reclaim overrides it.
    method Reap {job} {}

    # ─── Subscription ────────────────────────────────────────────────
    method subscribe {event cb} { dict lappend Subs $event $cb }
    method subscribed {event} { return [dict exists $Subs $event] }
    method _fire {event args} {
        if {![dict exists $Subs $event]} return
        foreach cb [dict get $Subs $event] { {*}$cb {*}$args }
    }

    # set_pre_launch_callback - a synchronous admission gate fired just
    # before each launch, as `{*}$cb $job $kind`. "abort" cancels the job
    # before any body runs; "defer" leaves it queued for a later walk,
    # which any enqueue, completion, release, resume, or pace re-drain
    # triggers; anything else admits it.
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
    # jobs are not active; they have not launched. Parked jobs are not active
    # either: they launched, but handed the slot back for the park.
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
    # parked_jobs - launched jobs waiting out an external window slot-free;
    # the read a supervisor bounds its launch-blind dispatch on.
    method parked_jobs {} {
        set out {}
        dict for {job state} $JobState {
            if {$state eq "parked"} { lappend out $job }
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
    # kind are active. The default cap is Jobs (no extra limit). This is
    # what lets one serial kind share a pool with parallel ones without a
    # second pool.
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

    # cancel - a queued job drops before it launches; a live job gets the
    # cancel signal and unwinds at its next checkpoint. A paused job takes
    # the cancel at its park.
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
        my SignalCancel $job $s
    }

    method pause_job {job} {
        if {![dict exists $JobState $job]} return
        if {[dict get $JobState $job] in $Terminal} return
        my SignalPause $job
    }
    method resume_job {job} {
        if {![dict exists $JobState $job]} return
        my SignalResume $job [dict get $JobState $job]
    }
    method pause_queue {} { set QueuePaused 1; my _fire queue-paused }
    method resume_queue {} {
        set QueuePaused 0
        my _fire queue-resumed
        my _try_launch
    }

    # prune_missing - drop every job whose key is not in $valid_jobs. A
    # caller that recomputes the set of jobs it still wants uses this to
    # shed the rest in one call. Launched jobs (running/paused/rate_limited/
    # parked) keep their state: their body is live and will reach a terminal
    # report on its own - a parked job holds no slot, but its coroutine is
    # still on the loop, so collecting it would orphan a running body. Only
    # terminal or not-yet-launched jobs are collectable.
    method prune_missing {valid_jobs} {
        set valid [dict create]
        foreach r $valid_jobs { dict set valid $r 1 }
        set dropped {}
        dict for {job state} $JobState {
            if {[dict exists $valid $job]} continue
            if {$state in {running paused rate_limited parked}} continue
            lappend dropped $job
        }
        foreach job $dropped {
            dict unset JobState $job
            catch {dict unset JobMeta $job}
            my ClearSignals $job
            # Reap, not just forget: a dropped job may still hold an
            # unretrieved per-launch record (a completion that pruned before
            # its own report, or a cancel routed through a caller that
            # prunes on the state event), so reclaim it here rather than
            # leak the record.
            my Reap $job
            set idx [lsearch -exact $Queue $job]
            if {$idx >= 0} { set Queue [lreplace $Queue $idx $idx] }
        }
        return [llength $dropped]
    }

    # requeue - move a terminal job back to queued for a retry. The
    # terminal transition already retracted any cancel or pause signal.
    method requeue {job} {
        if {![dict exists $JobState $job]} return
        if {[dict get $JobState $job] ni $Terminal} return
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
        if {![my _expect $job done {running paused rate_limited parked}]} return
        my _set_state $job done
        my Reap $job
        my _fire job-done $job $result
        my _try_launch
    }
    method on_failed {job reason} {
        if {![my _expect $job failed {running paused rate_limited parked}]} return
        my _set_state $job failed
        my Reap $job
        my _fire job-failed $job $reason
        my _try_launch
    }
    method on_cancelled {job} {
        # rate_limited is cancellable too: a job waiting out an external
        # limit still checkpoints, and its cancel must free the slot rather
        # than strand the job in rate_limited with the report refused. So is
        # parked: its checkpointing park loop is where a cancel lands, and
        # the terminal must take there without a detour through running.
        if {![my _expect $job cancelled {running paused rate_limited parked}]} return
        my _set_state $job cancelled
        my Reap $job
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
    # on_parked - the worker hands its slot back for the length of an
    # external window (a host gate, a quota reset) and keeps waiting where
    # it stands. The tally in _try_launch reads states, so the freed slot is
    # simply no longer counted; the immediate re-walk offers it to the queue.
    method on_parked {job note} {
        if {![my _expect $job parked running]} return
        my _set_state $job parked
        my _fire job-parked $job $note
        my _try_launch
    }
    # on_unparked - the window ended and the worker resumes. No cap re-check,
    # the same immediacy rate_limit_cleared has: the job already earned its
    # launch, and holding it now would strand a body the world has resumed.
    # The kind may transiently exceed its cap until the surplus drains.
    method on_unparked {job} {
        if {![my _expect $job unparked parked]} return
        my _set_state $job running
        my _fire job-unparked $job
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

    # _try_launch - walk the queue in order, launching any job that clears
    # every admission control. State flips to running at launch time, so
    # the cap math has no queued/running gap to race; how the body then
    # starts is the runtime's Launch (deferred, so no worker code runs
    # inside the walk). The active tallies are taken from the state map
    # once per walk and moved forward at each launch - a rescan per queued
    # job made a long held-back queue quadratic, and the enqueue-per-row
    # intake of a large board cubic. The controls fold in per job: the
    # lifetime count cap first (nothing more launches once it is hit), then
    # the global cap (stop and keep the tail), a held kind (announce once,
    # keep queued, scan on so other kinds launch), the per-kind cap, the
    # pacing floor (track the soonest wait and arm one coalesced re-drain),
    # and the admission gate.
    method _try_launch {} {
        if {$QueuePaused} return
        my forget $PaceTimer
        set PaceTimer ""
        set soonest ""
        set now [clock milliseconds]
        set active_n 0
        set active_kind [dict create]
        dict for {j st} $JobState {
            if {$st in {running paused rate_limited}} {
                incr active_n
                dict incr active_kind [dict get $JobMeta $j kind]
            }
        }
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
            if {$active_n >= $Jobs} {
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
            set kact [expr {[dict exists $active_kind $kind]
                            ? [dict get $active_kind $kind] : 0}]
            if {$kact >= $kcap} {
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
            incr active_n
            dict incr active_kind $kind
            dict set JobMeta $job started_at [clock milliseconds]
            my _set_state $job running
            my Launch $job
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
        if {$to in $Terminal} { my ClearSignals $job }
        my _fire job-state $job $to
    }
    method _log {msg} {
        catch {${LogService}::warn $msg}
        if {$LogCallback ne ""} { {*}$LogCallback "$LogName: $msg" }
    }
}

# jobloop - the engine run over coroutines: each admitted job's body is a
# coroutine this pool owns, its signals plain dicts read in-interpreter,
# its pause park a yield.
oo::class create jobloop {
    superclass ::jobloop::engine

    variable JobState JobMeta Terminal Reg LogName
    variable Coros CancelFlag PauseFlag Serial

    constructor {jobs args} {
        set LogName    jobloop
        set Coros      [dict create]
        set CancelFlag [dict create]
        set PauseFlag  [dict create]
        set Serial     0
        next $jobs {*}$args
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

    # ─── The runtime seam, over coroutines ───────────────────────────

    # Launch - arm the body on a 0 ms timer, off the queue walk, so no
    # worker code runs inline.
    method Launch {job} {
        my later 0 [list [namespace which my] _start $job]
    }
    method SignalCancel {job state} {
        dict set CancelFlag $job 1
        if {$state eq "paused"} { my _resume_coro $job }
    }
    method SignalPause {job} { dict set PauseFlag $job 1 }
    method SignalResume {job state} {
        catch {dict unset PauseFlag $job}
        if {$state eq "paused"} { my _resume_coro $job }
    }
    method ClearSignals {job} {
        catch {dict unset CancelFlag $job}
        catch {dict unset PauseFlag $job}
    }

    # job_of - the job a coroutine runs, "" for one this pool does not own:
    # the runtime's reverse map behind the worker self verb. Coros is small
    # (at most the launched, not-yet-finished jobs), so a walk suffices.
    method job_of {co} {
        dict for {job c} $Coros {
            if {$c eq $co} { return $job }
        }
        return ""
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

    # _start - fired by the launch's 0 ms timer. A cancel arriving in the
    # gap reports the cancellation instead of starting the body.
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
}
