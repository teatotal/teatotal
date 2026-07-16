package require Tcl 9
package require TclOO
package require json
package provide jobfeed 1.0

# jobfeed - the intake layer in front of a job pool: poll a work source,
# deduplicate what it hands back, deliver on-demand runs, admit through a
# policy gate, and retain each outcome as history.
#
# A job pool (jobloop or jobpool from this shelf) runs work and reports each
# job's lifecycle. What it does not do is decide WHICH work reaches it. Real
# work arrives from a source that has to be polled and may be slow or down;
# the same item can surface on two polls running and must not run twice at
# once; a person may deliver an item by hand and expect that delivery to be
# its own tracked run rather than folded onto whatever the poll found; a
# policy - a budget, a scope, a paused line - may want to admit or defer each
# launch; and once a job ends its outcome has to outlive it for a status
# view. Applications grow that intake one accessor at a time, and each grows
# it differently. jobfeed is that layer, built once, on top of the pool the
# caller already has.
#
#   set pool [jobloop new 8]
#   $pool register email [list $feed jobWorker]
#   set feed [jobfeed new [list $client fetch] runEmail $pool -interval 60]
#   $feed subscribe job-done {apply {{e d} {puts "$e $d"}}}
#   $feed start                       ;# begin polling the source
#   $feed inject news 42 email        ;# deliver one now, ahead of the poll
#
# THE SOURCE
#
# The source is a command prefix, called `{*}$source $callback`. It fetches
# the current work list however it likes - an async HTTP GET, a database
# read - and delivers it by invoking $callback with one argument, the list
# of work rows. An empty source ("") disables polling: start and pull skip
# it and emit pull-skip, for a feed that is fed only by inject. A row is a
# dict; the default intake reads `group`, `id`, and `poolkind` from it, and a
# consumer whose rows are shaped differently overrides onWorkQueue.
#
# IDENTITY, DEDUP, AND DELIVERY
#
# Every work item has an identity: a (group, id) pair. A polled item keys on
# its identity alone ("group:id") and deduplicates - if an item of that
# identity is already live (queued or running), the second is dropped, so a
# slow job still on the pool is never launched twice. A delivered item
# (inject) is a NEW run every time: a per-identity sequence mints it its own
# key "group:id#N", its own queue entry, its own history row, so successive
# deliveries of one identity read apart instead of folding together.
#
# THE WORKER AND THE DISPATCH
#
# The pool runs each job through jobfeed's jobWorker, which calls the
# caller's dispatch command prefix once and stashes the one result line it
# returns on the job. The pool's job-done then drives reapCore, which reads
# that line back. Register the pool's kinds at `[list $feed jobWorker]`; the
# dispatch is whatever runs the actual work and returns a result line (JSON
# by default, so its status can be read back).
#
# THE GATE
#
# The pool's pre-launch callback is wired to the feed's gate. The default
# admits everything; a consumer overrides gate to return "defer" for an item
# its policy is not ready to launch (a spent budget, an off-scope class, a
# paused line). A deferred item stays queued, holds no slot, and is weighed
# again on the next walk - it costs no launch. Delivered items are enqueued
# at priority 1, ahead of polled work.
#
# HISTORY AND THE EVENT STREAM
#
# A live item sits in Items until it is reaped; on completion its outcome
# lands in History (group, id, status, detail, version, origin, ts) and stays
# there for a status view. subscribe registers an observer called with every
# emitted (event, detail); the feed emits job-inject when a delivery is
# announced, job-start when the worker begins, job-done when a job is reaped,
# and pull-skip when a poll finds no source. A consumer with events of its
# own (a board refresh, a policy notice) emits them through the same seam.
#
# THE HOOKS
#
# Seven methods carry the default behaviour and are the override points for a
# consumer's policy: gate (admission), classifyOutcome (read a result line
# into status/detail/version), onOutcome (act on an outcome, e.g. feed a
# breaker), replySock (answer a parked request), startLabel and dispatchArgs
# (shape the worker's job-start notice and the dispatch's arguments), and
# _sink (a second home for every emitted event, e.g. a log). A consumer
# subclasses jobfeed and overrides the ones its policy needs, the same
# subclassing idiom jobloop's reporting surface uses.
#
# Written against Tcl 9. Copyright (c) 2025 Weiwu Zhang, MIT license.

namespace eval ::jobfeed {
    # boolish - the lenient truthiness a knob's user input wants.
    proc _bool {v} { return [expr {[string is true -strict $v] || $v eq "1" ? 1 : 0}] }
    # dget - dict get with a default for an absent key.
    proc _dget {d key {default ""}} {
        if {[dict exists $d $key]} { return [dict get $d $key] }
        return $default
    }
    # jstr - a JSON string literal, escaped.
    proc _jstr {s} {
        return "\"[string map {\\ \\\\ \" \\\" \n \\n \r \\r \t \\t} $s]\""
    }
}

oo::class create jobfeed {
    # Source: the polled work-source command prefix ("" disables polling).
    # Dispatch: the worker command prefix jobWorker calls. Pool: the caller's
    # job pool this feed enqueues into. Poll/PollInterval: the poll heartbeat.
    variable Source Dispatch Pool Poll PollInterval
    # Items: live key -> item dict, added at enqueue, dropped at reap. History:
    # key -> finished outcome dict. RunSeq: "group:id" -> delivery sequence.
    # Observers: subscriber command prefixes. PollAfter/NextPoll: the armed
    # poll timer token and its epoch-seconds deadline ("" when none). WorkList:
    # the last polled work list, the read model a status view reads back.
    variable Items History RunSeq Observers PollAfter NextPoll WorkList

    constructor {source dispatch pool args} {
        set Source $source
        set Dispatch $dispatch
        set Pool $pool
        set Poll 1
        set PollInterval 60
        foreach {opt val} $args {
            switch -- $opt {
                -poll     { set Poll [jobfeed::_bool $val] }
                -interval { set PollInterval $val }
                default   { error "jobfeed: unknown option $opt" }
            }
        }
        set Items [dict create]
        set History [dict create]
        set RunSeq [dict create]
        set Observers {}
        set PollAfter ""; set NextPoll ""
        set WorkList {}
        # Wire the pool: the feed's gate is its pre-launch admission callback,
        # and its reap fires off the pool's own job-done / job-failed.
        $Pool set_pre_launch_callback [list [self] gate]
        $Pool subscribe job-done   [list [self] onPoolDone]
        $Pool subscribe job-failed [list [self] onPoolFailed]
    }

    destructor {
        # The pool is the caller's; the caller (or a subclass) owns its
        # teardown. Cancel the poll heartbeat so no armed timer fires into a
        # gone object.
        if {$PollAfter ne ""} { catch {after cancel $PollAfter} }
    }

    # ─── Polling ─────────────────────────────────────────────────────

    # start - begin operating: one poll (which re-arms the heartbeat) when
    # polling is on, else sit idle until an inject drives work.
    method start {} { if {$Poll} { my pull } }

    # pull - poll the source and re-arm the heartbeat. A remote source must
    # never stall the loop, so the source is asked asynchronously (it answers
    # onWorkQueue when the rows are in). An empty source skips.
    method pull {} {
        set PollAfter ""
        if {$Source eq ""} {
            my emit pull-skip "no work source configured"
        } else {
            {*}$Source [list [self] onWorkQueue]
        }
        if {$Poll} {
            set PollAfter [after [expr {$PollInterval * 1000}] [list [self] pull]]
            set NextPoll [expr {[clock seconds] + $PollInterval}]
        } else {
            set NextPoll ""
        }
    }

    # pullNow - a one-shot poll that does not touch the heartbeat.
    method pullNow {} {
        if {$Source eq ""} { my emit pull-skip "no work source configured"; return }
        {*}$Source [list [self] onWorkQueue]
    }

    # setPoll - turn the poll heartbeat on or off, arming or cancelling the
    # timer to match.
    method setPoll {v} {
        set Poll [jobfeed::_bool $v]
        my emit config "poll=$Poll"
        if {$Poll && $PollAfter eq ""} {
            my pull
        } elseif {!$Poll && $PollAfter ne ""} {
            after cancel $PollAfter
            set PollAfter ""; set NextPoll ""
        }
        return $Poll
    }

    # ─── Intake ──────────────────────────────────────────────────────

    # onWorkQueue - the poll callback: record the work list for the read
    # model, then enqueue every row as polled work. The default reads group,
    # id, and poolkind off each row dict; a consumer with richer rows (a
    # blocked flag, batched rows, a scope filter) overrides this and calls
    # enqueue with its own extraction.
    method onWorkQueue {rows} {
        set WorkList $rows
        set added 0
        foreach row $rows {
            if {![dict exists $row id]} continue
            if {[my _enqueue [jobfeed::_dget $row group] [dict get $row id] \
                    [jobfeed::_dget $row poolkind] 0 {}] ne ""} { incr added }
        }
        my emit job-board "[llength $rows] rows, $added newly queued"
    }

    # enqueue - add one work item. A polled item (delivered 0) deduplicates by
    # identity against everything live and keys "group:id"; a delivered item
    # (delivered 1) mints its own "group:id#N" and always takes. opts is an
    # arbitrary dict merged into the item, for a consumer's own fields. Returns
    # the item's key, "" when deduplicated away.
    method enqueue {group id poolkind delivered {opts {}}} {
        return [my _enqueue $group $id $poolkind $delivered $opts]
    }

    # _enqueue - the add mechanism behind enqueue, factored out so a subclass
    # whose own enqueue takes a different argument shape can funnel through the
    # same dedup, mint, announce, and hand-off rather than repeat them.
    method _enqueue {group id poolkind delivered opts} {
        if {$delivered} {
            dict incr RunSeq "$group:$id"
            set key "$group:$id#[dict get $RunSeq "$group:$id"]"
        } else {
            if {[my workLive $group $id] ne ""} { return "" }
            set key "$group:$id"
        }
        set item [dict merge [dict create \
            key $key group $group id $id poolkind $poolkind delivered $delivered \
            sock "" origin "" line "" ts [clock seconds]] $opts]
        dict set Items $key $item
        # A delivery announces itself before the pool can launch it, so an
        # observer sees job-inject ahead of job-start; a polled row is silent.
        if {$delivered} {
            my emit job-inject [dict create key $key group $group id $id \
                origin [jobfeed::_dget $item origin]]
        }
        my poolEnqueue $key
        return $key
    }

    # inject - deliver one item on demand, ahead of the poll. If an item of
    # this identity is already live, the delivery promotes it or answers
    # duplicate (promoteOrDup); otherwise it mints a delivered run. Either way
    # the pool is re-weighed so the delivery is seen at once.
    method inject {group id poolkind {sock ""} {origin ""}} {
        set hit [my workLive $group $id]
        if {$hit ne ""} {
            my promoteOrDup $hit $group $id $sock $origin
        } else {
            my _enqueue $group $id $poolkind 1 [dict create sock $sock origin $origin]
        }
        my drain
    }

    # workLive - the live key for an identity (group, id), queued or running,
    # or "" when none. Matched by identity, never by the key string, so a
    # polled "group:id" and a delivered "group:id#N" of one identity both find
    # it.
    method workLive {group id} {
        dict for {key it} $Items {
            if {[dict get $it group] eq $group && [dict get $it id] eq $id} {
                return $key
            }
        }
        return ""
    }

    # poolEnqueue - hand one item to the pool on its poolkind, delivered work
    # at priority 1 so it launches ahead of polled work. A terminal record for
    # this key lingering in the pool (a re-delivery, a re-polled failed row) is
    # pruned first so the re-enqueue takes.
    method poolEnqueue {key} {
        set item [dict get $Items $key]
        if {[$Pool state $key] in {done failed cancelled}} {
            set valid {}
            dict for {k _} $Items { if {$k ne $key} { lappend valid $k } }
            $Pool prune_missing $valid
        }
        set prio [expr {[dict get $item delivered] ? 1 : 0}]
        $Pool enqueue $key [dict get $item poolkind] {} -priority $prio
    }

    # promoteOrDup - a delivery matched a live item. A QUEUED polled item is
    # promoted in place (delivered 1, the delivery's sock and origin attached),
    # because the source's row and the person's ask are one item, not two. A
    # queued delivery, or a running item, answers duplicate: one live run per
    # identity. The parked request is answered either way, so it never leaks.
    method promoteOrDup {key group id sock origin} {
        set it [dict get $Items $key]
        if {[$Pool state $key] eq "queued" && ![dict get $it delivered]} {
            dict set it delivered 1
            dict set it sock $sock
            dict set it origin $origin
            dict set Items $key $it
            my emit job-inject [dict create key $key group $group id $id \
                origin $origin promoted 1]
            return
        }
        my emit job-dup [dict create key "$group:$id" group $group id $id origin $origin]
        if {$sock ne ""} { my replySock $sock "{\"queued\":true,\"duplicate\":true}" }
    }

    # ─── Draining ────────────────────────────────────────────────────

    # drain - nudge the pool to re-weigh its queue. The pool re-walks on its
    # own after enqueue, completion, hold release and pace; a policy change
    # (a widened scope, a cleared budget) has no such trigger of its own, so
    # those knobs call this.
    method drain {} { $Pool resume_queue }

    # ─── The worker and the reap ─────────────────────────────────────

    # jobWorker - the pool's worker, run inside the coroutine (or thread) the
    # pool owns. It calls the dispatch once and stashes the one result line on
    # the item; the pool's job-done then drives reapCore to read it back. A
    # dispatch that throws unwinds to the pool's failure path, reaped as an
    # error.
    method jobWorker {job opts} {
        if {$Dispatch eq ""} { error "no dispatch configured" }
        set item [dict get $Items $job]
        my emit job-start "[my startLabel $item] $job"
        set line [{*}$Dispatch {*}[my dispatchArgs $item]]
        dict set Items $job line $line
    }

    # onPoolDone - a job the worker finished cleanly: reap the line it stashed.
    method onPoolDone {job result} {
        if {![dict exists $Items $job]} return
        my reapCore $job [dict get $Items $job line]
    }

    # onPoolFailed - a job whose worker threw: build the error result line
    # from the reason and reap it.
    method onPoolFailed {job reason} {
        if {![dict exists $Items $job]} return
        my reapCore $job "{\"status\":\"error\",\"detail\":[jobfeed::_jstr $reason]}"
    }

    # reapCore - the single completion point for every job: classify the
    # result line, act on the outcome, retain a history row, answer a parked
    # request, and emit job-done. The pool has freed the slot and re-walks
    # after this fires, so there is no drain here.
    method reapCore {key line} {
        if {![dict exists $Items $key]} return
        set item [dict get $Items $key]
        dict unset Items $key
        set line [string trim $line]
        if {$line eq ""} { set line "{\"status\":\"error\",\"detail\":\"job produced no result\"}" }
        lassign [my classifyOutcome $item $line] status detail version
        my onOutcome $item $status $detail
        dict set History $key [dict create \
            group [dict get $item group] id [dict get $item id] \
            status $status detail $detail version $version \
            origin [jobfeed::_dget $item origin] ts [clock seconds]]
        my emit job-done "$key $line"
        set sock [jobfeed::_dget $item sock]
        if {$sock ne ""} { my replySock $sock $line }
    }

    # ─── The read model ──────────────────────────────────────────────

    # workQueue - the last polled work list.
    method workQueue {} { return $WorkList }

    # history - the retained outcome of every reaped job (key -> outcome dict),
    # the read model a status view reads a finished job's fate from.
    method history {} { return $History }

    # job - a snapshot of every live item (no request/channel internals).
    method job {} {
        set out {}
        dict for {key it} $Items {
            set state [expr {[$Pool state $key] eq "queued" ? "queued" : "running"}]
            lappend out [dict create key $key group [dict get $it group] \
                id [dict get $it id] poolkind [dict get $it poolkind] \
                state $state delivered [dict get $it delivered]]
        }
        return $out
    }

    # nextPoll / pollInterval - the poll heartbeat's deadline and period, for a
    # status view's idle countdown.
    method nextPoll {} { return $NextPoll }
    method pollInterval {} { return $PollInterval }
    method isPolling {} { return $Poll }

    # ─── Observers ───────────────────────────────────────────────────

    method subscribe {cb} { lappend Observers $cb; return $cb }
    method unsubscribe {cb} {
        set idx [lsearch -exact $Observers $cb]
        if {$idx >= 0} { set Observers [lreplace $Observers $idx $idx] }
    }

    # emit - fan a state change to the second sink (a log, by default nothing)
    # and to every observer. The one place both are fed, so they cannot drift.
    method emit {event detail} {
        my _sink $event $detail
        foreach cb $Observers { catch { uplevel #0 [list {*}$cb $event $detail] } }
    }

    # ─── Hooks (the override points) ─────────────────────────────────

    # gate - the pool's pre-launch admission callback. The default admits
    # everything; override to return "defer" for an item a policy is not ready
    # to launch (it stays queued, holds no slot, is weighed again next walk) or
    # "abort" to drop it.
    method gate {job kind} { return "" }

    # classifyOutcome - read a result line into {status detail version}. The
    # default parses a JSON object's status (default "done"), detail, and
    # version, and calls an unparseable line an error. Override to normalise a
    # consumer's own status vocabulary.
    method classifyOutcome {item line} {
        set status done; set detail ""; set version ""
        if {![catch {json::json2dict $line} res]} {
            if {[dict exists $res status]}  { set status  [dict get $res status] }
            if {[dict exists $res detail]}  { set detail  [dict get $res detail] }
            if {[dict exists $res version]} { set version [dict get $res version] }
        } else {
            set status error; set detail "unparseable result: $line"
        }
        return [list $status $detail $version]
    }

    # onOutcome - act on a reaped outcome (its status and detail). The default
    # does nothing; override to feed a circuit breaker or a tally.
    method onOutcome {item status detail} {}

    # replySock - answer a parked request that rode on the item's sock. The
    # default does nothing; override to write the line back to a socket.
    method replySock {sock line} {}

    # startLabel - the leading word of the job-start notice. Override to name
    # the worker's mode.
    method startLabel {item} { return run }

    # dispatchArgs - the arguments jobWorker passes to the dispatch. The
    # default is {poolkind group id}; override to shape a consumer's own
    # dispatch contract.
    method dispatchArgs {item} {
        return [list [dict get $item poolkind] [dict get $item group] [dict get $item id]]
    }

    # _sink - a second home for every emitted event (a log, a health var). The
    # default drops it; override to tee the stream.
    method _sink {event detail} {}
}
