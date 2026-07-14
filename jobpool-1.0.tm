package require Tcl 9
package require TclOO
package require Thread
package provide jobpool 1.0

# jobpool - a worker pool that owns each job's lifecycle, not just its
# thread.
#
# tpool runs your jobs and hands back a result; nothing between the post
# and the result is yours to steer. You cannot cancel a job that is
# already running, pause the queue while a dialog is up, hold one kind of
# job to a single worker while the rest fan out, or watch a row move
# through its states without polling. jobpool is that missing layer: one
# shared pool of pre-spawned worker threads, a per-row state machine
# (queued, running, paused, rate_limited, and the terminals done/failed/
# cancelled), cooperative cancel and pause of a *running* job through a
# sentinel the worker polls, a global concurrency cap with a per-kind
# sub-cap inside it, and an event stream a view can subscribe to instead
# of decoding thread messages by hand.
#
#   set pool [jobpool new 8 -init {source workers.tcl}]
#   $pool subscribe row-state {apply {{row st} {puts "$row -> $st"}}}
#   $pool set_worker_cap upload 1          ;# uploads serialise; rest fan out
#   $pool enqueue job42 render render_one {file a.blend}
#   $pool cancel job42                     ;# reaches it even mid-render
#
# THE POOL AND ITS WORKERS
#
# Workers live in the thread pool's own interpreters, seeded once from the
# -init script. That script defines the worker procs (a row is posted as
# `<worker> <row> <opts>`) and whatever they need; jobpool adds three
# globals to it before it runs - ::main_tid and ::dispatcher, so a worker
# can message home, and ::jobpool_tsv, the shared-variable array a worker
# polls for its cancel and pause sentinels. A worker reports progress and
# completion by calling back into the pool object across threads (the
# message surface below); it stays cancellable by checking the sentinels
# at its own safe points.
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
# THE ROW STATE MACHINE
#
#   queued -> running -> done|failed|cancelled
#   running <-> paused           (user hold, via the pause sentinel)
#   running <-> rate_limited     (worker waiting on an external limit)
#   queued  -> cancelled         (dropped before it ever posts)
#
# running, paused and rate_limited each hold a worker slot; queued does
# not. A cancel on a queued row drops it in place; on a running row it
# sets the sentinel and waits for the worker to notice and report back.
#
# THE MESSAGE SURFACE (worker thread -> pool, via thread::send -async)
#
# A worker calls these on the pool object; each runs on the pool's own
# thread. State-changing messages are validated against the row's current
# state and dropped (with a diagnostic) when they do not fit, so a message
# that arrives after the row was cancelled cannot resurrect it.
#
#   on_phase row name          informational: entered a named phase
#   on_progress row text       informational: freeform progress text
#   on_rate_limited row until   running -> rate_limited (holds the slot)
#   on_rate_limit_cleared row   rate_limited -> running
#   on_paused row               running -> paused (worker saw the sentinel)
#   on_resumed row              paused -> running
#   on_done row ?result?        -> done
#   on_failed row reason        -> failed
#   on_cancelled row            -> cancelled (worker saw the sentinel)
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
# row-state fires on every transition (row, new-state); the finer events
# row-phase, row-progress, row-done, row-failed, row-paused, row-resumed,
# row-rate-limited, row-rate-limit-cleared carry each message on. A Tk view
# subscribes to row-state and repaints; a headless run subscribes to
# row-done and collects.
#
# Written against Tcl 9. Copyright (c) 2025 Weiwu Zhang, MIT license.

oo::class create jobpool {
    variable Pool Jobs WorkerCap
    variable Queue RowState RowMeta RowJobId
    variable QueuePaused
    variable LogCallback LogService PrePostCallback Subs Sentinels
    variable Terminal

    constructor {jobs args} {
        set Jobs            $jobs
        set WorkerCap       [dict create]
        set Queue           {}
        set RowState        [dict create]
        set RowMeta         [dict create]
        set RowJobId        [dict create]
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
            set ::dispatcher [list $me]
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

    # set_pre_post_callback - a synchronous gate fired just before each
    # post, as `{*}$cb $row $kind $idx $total`. A return of "abort"
    # cancels the row before any worker runs; anything else lets it post.
    # idx is the row's 1-based position in the state map, total its size,
    # a stable rising position a step-through UI can gate on.
    method set_pre_post_callback {cb} { set PrePostCallback $cb }

    # ─── Accessors ───────────────────────────────────────────────────
    method state {row} {
        if {[dict exists $RowState $row]} { return [dict get $RowState $row] }
        return ""
    }
    method kind_of {row} {
        if {[dict exists $RowMeta $row]} { return [dict get $RowMeta $row kind] }
        return ""
    }
    method count_by_kind {kind state} {
        set n 0
        dict for {row meta} $RowMeta {
            if {[dict get $meta kind] ne $kind} continue
            if {[dict get $RowState $row] ne $state} continue
            incr n
        }
        return $n
    }
    # active_rows - rows holding a worker slot: posted, not yet terminal.
    # Queued rows are not active; they have not posted.
    method active_rows {} {
        set out {}
        dict for {row state} $RowState {
            if {$state in {running paused rate_limited}} { lappend out $row }
        }
        return $out
    }
    method queued_rows {} {
        set out {}
        dict for {row state} $RowState {
            if {$state eq "queued"} { lappend out $row }
        }
        return $out
    }
    method all_rows {} { return [dict keys $RowState] }
    method is_queue_paused {} { return $QueuePaused }
    method jobs_cap {} { return $Jobs }
    method posted_count {} { return [llength [my active_rows]] }

    # set_worker_cap - a per-kind concurrency sub-cap inside the global
    # Jobs cap. A row of this worker kind posts only while fewer than
    # <cap> of its kind are active. The default cap is Jobs (no extra
    # limit). This is what lets one serial kind share a pool with parallel
    # ones without a second pool.
    method set_worker_cap {worker cap} { dict set WorkerCap $worker $cap }

    method _active_count_for_worker {worker} {
        set n 0
        foreach row [my active_rows] {
            if {[dict get $RowMeta $row worker] eq $worker} { incr n }
        }
        return $n
    }

    # ─── Mutators ────────────────────────────────────────────────────

    # enqueue - register a row with its kind, the worker proc that runs
    # it, and the opts dict the worker receives.
    method enqueue {row kind worker opts} {
        if {[dict exists $RowState $row]} {
            my _log "enqueue: row $row already present (state [dict get $RowState $row]); ignoring"
            return
        }
        dict set RowState $row queued
        dict set RowMeta  $row [dict create \
            kind       $kind \
            worker     $worker \
            opts       $opts \
            posted_at  [clock milliseconds] \
            started_at ""]
        lappend Queue $row
        my _fire row-state $row queued
        my _try_post_next
    }

    # cancel - a queued row drops before it posts; a running row gets the
    # cancel sentinel and reports back when the worker next checks.
    method cancel {row} {
        if {![dict exists $RowState $row]} return
        set s [dict get $RowState $row]
        if {$s eq "queued"} {
            set idx [lsearch -exact $Queue $row]
            if {$idx >= 0} { set Queue [lreplace $Queue $idx $idx] }
            my _set_state $row cancelled
            return
        }
        if {$s in $Terminal} return
        tsv::set $Sentinels $row.cancel 1
    }

    method pause_row {row} {
        if {![dict exists $RowState $row]} return
        if {[dict get $RowState $row] in $Terminal} return
        tsv::set $Sentinels $row.pause 1
    }
    method resume_row {row} {
        if {![dict exists $RowState $row]} return
        catch {tsv::unset $Sentinels $row.pause}
    }
    method pause_queue {} { set QueuePaused 1; my _fire queue-paused }
    method resume_queue {} {
        set QueuePaused 0
        my _fire queue-resumed
        my _try_post_next
    }

    # prune_missing - drop rows whose key is not in $valid_rows, so a
    # state map can shed entries a view refresh removed. Active rows
    # (running/paused/rate_limited) keep their state: they own a slot and
    # will reach a terminal message on their own. Only terminal or
    # not-yet-posted rows are collectable.
    method prune_missing {valid_rows} {
        set valid [dict create]
        foreach r $valid_rows { dict set valid $r 1 }
        set dropped {}
        dict for {row state} $RowState {
            if {[dict exists $valid $row]} continue
            if {$state in {running paused rate_limited}} continue
            lappend dropped $row
        }
        foreach row $dropped {
            dict unset RowState $row
            catch {dict unset RowMeta  $row}
            catch {dict unset RowJobId $row}
            set idx [lsearch -exact $Queue $row]
            if {$idx >= 0} { set Queue [lreplace $Queue $idx $idx] }
            catch {tsv::unset $Sentinels $row.cancel}
            catch {tsv::unset $Sentinels $row.pause}
        }
        return [llength $dropped]
    }

    # requeue - move a terminal row back to queued for a retry, clearing
    # any prior sentinel.
    method requeue {row} {
        if {![dict exists $RowState $row]} return
        if {[dict get $RowState $row] ni $Terminal} return
        catch {tsv::unset $Sentinels $row.cancel}
        catch {tsv::unset $Sentinels $row.pause}
        dict set RowMeta $row started_at ""
        my _set_state $row queued
        lappend Queue $row
        my _try_post_next
    }

    # ─── Worker → pool messages ──────────────────────────────────────

    method on_phase {row phase} {
        if {![my _expect_active $row phase]} return
        my _fire row-phase $row $phase
    }
    method on_progress {row text} {
        if {![my _expect_active $row progress]} return
        my _fire row-progress $row $text
    }
    method on_done {row {result {}}} {
        if {![my _expect $row done {running paused rate_limited}]} return
        my _set_state $row done
        my _fire row-done $row $result
        my _try_post_next
    }
    method on_failed {row reason} {
        if {![my _expect $row failed {running paused rate_limited}]} return
        my _set_state $row failed
        my _fire row-failed $row $reason
        my _try_post_next
    }
    method on_cancelled {row} {
        if {![my _expect $row cancelled {running paused}]} return
        my _set_state $row cancelled
        catch {tsv::unset $Sentinels $row.cancel}
        my _try_post_next
    }
    method on_rate_limited {row until} {
        if {![my _expect $row rate_limited running]} return
        my _set_state $row rate_limited
        my _fire row-rate-limited $row $until
    }
    method on_rate_limit_cleared {row} {
        if {![my _expect $row rate_limit_cleared rate_limited]} return
        my _set_state $row running
        my _fire row-rate-limit-cleared $row
    }
    method on_paused {row} {
        if {![my _expect $row paused running]} return
        my _set_state $row paused
        my _fire row-paused $row
    }
    method on_resumed {row} {
        if {![my _expect $row resumed paused]} return
        my _set_state $row running
        my _fire row-resumed $row
    }

    # ─── Internals ───────────────────────────────────────────────────

    # _try_post_next - walk the queue in order, posting any row that fits
    # both the global cap and its per-kind cap. State flips to running at
    # post time, not on a later message, so the cap math reads straight
    # from the state map and there is no queued/running gap to race. A
    # row blocked only by its per-kind cap stays queued while the scan
    # continues, so other kinds still post - per-kind FIFO under
    # contention, parallel across kinds.
    method _try_post_next {} {
        if {$QueuePaused} return
        set new_queue {}
        set i 0
        while {$i < [llength $Queue]} {
            set row [lindex $Queue $i]
            incr i
            if {![dict exists $RowState $row]} continue
            if {[dict get $RowState $row] ne "queued"} continue
            if {[llength [my active_rows]] >= $Jobs} {
                lappend new_queue $row
                while {$i < [llength $Queue]} {
                    lappend new_queue [lindex $Queue $i]
                    incr i
                }
                break
            }
            set meta   [dict get $RowMeta $row]
            set worker [dict get $meta worker]
            set wcap [expr {[dict exists $WorkerCap $worker]
                            ? [dict get $WorkerCap $worker] : $Jobs}]
            if {[my _active_count_for_worker $worker] >= $wcap} {
                lappend new_queue $row
                continue
            }
            set opts [dict get $meta opts]
            set kind [dict get $meta kind]
            if {$PrePostCallback ne ""} {
                set total [dict size $RowState]
                set idx 0
                dict for {r _} $RowState {
                    incr idx
                    if {$r eq $row} break
                }
                set verdict ""
                catch {set verdict [{*}$PrePostCallback $row $kind $idx $total]}
                if {$verdict eq "abort"} {
                    my _set_state $row cancelled
                    continue
                }
            }
            dict set RowMeta $row started_at [clock milliseconds]
            my _set_state $row running
            dict set RowJobId $row \
                [tpool::post -nowait $Pool [list $worker $row $opts]]
        }
        set Queue $new_queue
    }

    # _expect - the row's state must be one of allowed_from for this
    # transition; log and refuse otherwise.
    method _expect {row transition allowed_from} {
        if {![dict exists $RowState $row]} {
            my _log "$transition for unknown row $row; dropping"
            return 0
        }
        set cur [dict get $RowState $row]
        if {$cur ni $allowed_from} {
            my _log "$transition for row $row in state $cur (allowed: [join $allowed_from {, }]); dropping"
            return 0
        }
        return 1
    }
    # _expect_active - an informational message is allowed in any
    # non-terminal state.
    method _expect_active {row mtype} {
        if {![dict exists $RowState $row]} {
            my _log "$mtype for unknown row $row; dropping"
            return 0
        }
        if {[dict get $RowState $row] in $Terminal} {
            my _log "$mtype for row $row in terminal state [dict get $RowState $row]; dropping"
            return 0
        }
        return 1
    }
    method _set_state {row to} {
        dict set RowState $row $to
        my _fire row-state $row $to
    }
    method _log {msg} {
        catch {${LogService}::warn $msg}
        if {$LogCallback ne ""} { {*}$LogCallback "jobpool: $msg" }
    }
}
