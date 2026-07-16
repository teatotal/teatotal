#!/usr/bin/env tclsh9.0
# Tests for the jobfeed module: the intake layer in front of a job pool.
# Dedup of polled identities, delivered runs minting their own sequenced key,
# the admission gate deferring in place, the reap into history, promote-or-dup
# on a delivery that meets a live item, and the event stream. The pool here is
# a real jobloop; the source and dispatch are invented for the tests, and the
# module knows nothing of any program that uses it.
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add $ROOT
package require jobfeed
package require jobloop

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name"
        puts "  expected: <$expected>"
        puts "  actual:   <$actual>"
        incr ::fails
    } else {
        puts "ok:   $name"
    }
}
proc drain {{ms 60}} {
    set ::_drained 0
    after $ms {set ::_drained 1}
    vwait ::_drained
}

# A dispatch that echoes back a controllable result line. ::plan maps
# "group:id" -> the JSON line to return, defaulting to a done line.
set ::ran {}
proc dispatch {poolkind group id} {
    lappend ::ran "$group:$id"
    if {[info exists ::plan($group:$id)]} { return $::plan($group:$id) }
    return "{\"status\":\"done\",\"detail\":\"ok\"}"
}

# A source cmdprefix: hands the callback whatever ::rows currently holds.
set ::rows {}
proc source_cb {callback} { {*}$callback $::rows }

# One test subclass exercising the override seam the module's contract rests
# on: a togglable admission gate, and an onOutcome hook that records each
# reaped outcome. A consumer overrides exactly these methods; the test stands
# in for one.
oo::class create TestFeed {
    superclass jobfeed
    variable Admit Seen Replies Abort Clobber
    method admit {v} { set Admit $v }
    method abortnext {} { set Abort 1 }          ;# gate aborts the next launch (F1)
    method clobbernext {} { set Clobber 1 }      ;# classifyOutcome returns clobbering extra (F4)
    method seen {} { return [expr {[info exists Seen] ? $Seen : {}}] }
    method replies {} { return [expr {[info exists Replies] ? $Replies : {}}] }
    method gate {job kind} {
        if {[info exists Abort] && $Abort} { set Abort 0; return abort }
        if {[info exists Admit] && !$Admit} { return defer }
        return ""
    }
    method classifyOutcome {item line} {
        if {[info exists Clobber] && $Clobber} {
            return [list done "d" [dict create status OVERRIDDEN id ZZZ mine 1]]
        }
        return [next $item $line]
    }
    method onOutcome {item status detail} {
        lappend Seen "[dict get $item group]:[dict get $item id]=$status"
    }
    method reply {to body} { lappend Replies "$to=$body" }
    method duplicateReply {group id} { return "dup:$group:$id" }
}

# ── polled dedup: one identity, enqueued twice, stays one live item ──────────

set pool [jobloop new 8]
set feed [jobfeed new [list source_cb] dispatch $pool -poll 0]
$pool register work [list $feed jobWorker]
$pool hold_kind work
check enqueue-first  "AI:1" [$feed enqueue AI 1 work 0]
check enqueue-dup    ""     [$feed enqueue AI 1 work 0]
check worklive-hit   "AI:1" [$feed workLive AI 1]
$feed destroy
$pool destroy

# ── delivered runs mint their own sequenced key ─────────────────────────────

set pool [jobloop new 8]
set feed [jobfeed new "" dispatch $pool -poll 0]
$pool register work [list $feed jobWorker]
$pool hold_kind work
check deliver-1 "BI:2#1" [$feed enqueue BI 2 work 1]
check deliver-2 "BI:2#2" [$feed enqueue BI 2 work 1]
check deliver-other "BI:3#1" [$feed enqueue BI 3 work 1]
$feed destroy
$pool destroy

# ── the gate defers in place: a deferred item holds no slot, stays queued ────

set pool [jobloop new 8]
set feed [TestFeed new "" dispatch $pool -poll 0]
$pool register work [list $feed jobWorker]
$feed admit 0
$feed enqueue AI 9 work 0
drain
check gate-defers-queued "queued" [$pool state AI:9]
check gate-no-launch     "0"      [llength [$pool active_jobs]]
$feed admit 1
$feed drain
drain
# reapCore prunes the pool's terminal record (F3), so the completed outcome is
# read from the feed's history rather than the pool's (now absent) state.
check gate-admits-after "done" [dict get [$feed history] AI:9 status]
$feed destroy
$pool destroy

# ── reap into history, with a subclass onOutcome hook fed the outcome ────────

set pool [jobloop new 8]
set feed [TestFeed new "" dispatch $pool -poll 0]
$pool register work [list $feed jobWorker]
$feed admit 1
set ::done_seen {}
$feed subscribe [list apply {{e d} {
    if {$e eq "job-done"} { lappend ::done_seen $d }
}}]
set ::plan(CI:5) "{\"status\":\"error\",\"detail\":\"boom\"}"
$feed enqueue CI 5 work 0
drain
check reap-live-cleared     "" [$feed workLive CI 5]
check reap-outcome-hook     "CI:5=error" [$feed seen]
check reap-emitted-job-done 1 [expr {[llength $::done_seen] == 1 && \
    [string match "CI:5 *boom*" [lindex $::done_seen 0]]}]
$feed destroy
$pool destroy

# ── promote-or-dup: delivering a queued polled item promotes it in place ─────

set pool [jobloop new 8]
set feed [jobfeed new "" dispatch $pool -poll 0]
$pool register work [list $feed jobWorker]
$pool hold_kind work                       ;# keep the polled item queued
set ::injects {}
$feed subscribe [list apply {{e d} {
    if {$e eq "job-inject"} { lappend ::injects $d }
}}]
$feed enqueue DI 7 work 0                   ;# a polled item, now queued
set live [$feed workLive DI 7]
$feed promoteOrDup $live DI 7 "" WEB
check promote-key-same "DI:7" $live
set jrow [lindex [$feed job] 0]
check promote-now-delivered "1" [dict get $jrow delivered]
check promote-emitted-inject 1 [expr {[llength $::injects] == 1 && \
    [dict get [lindex $::injects 0] promoted] == 1 && \
    [dict get [lindex $::injects 0] group] eq "DI"}]
$feed destroy
$pool destroy

# ── polling: pull runs the source and enqueues its rows ─────────────────────

set pool [jobloop new 8]
$pool hold_kind work
set feed [jobfeed new [list source_cb] dispatch $pool -poll 0]
$pool register work [list $feed jobWorker]
set ::rows [list \
    [dict create group EI id 1 poolkind work] \
    [dict create group EI id 2 poolkind work] \
    [dict create group EI id 1 poolkind work]]   ;# a dup id in one poll
$feed pullNow
drain
set keys {}
foreach r [$feed job] { lappend keys [dict get $r key] }
check poll-enqueued-deduped [lsort {EI:1 EI:2}] [lsort $keys]
check poll-workqueue-recorded 3 [llength [$feed workQueue]]
$feed destroy
$pool destroy

# ── reply: a reaped item with a reply token gets the result line sent back ───

set pool [jobloop new 8]
set feed [TestFeed new "" dispatch $pool -poll 0]
$pool register work [list $feed jobWorker]
$feed admit 1
set ::plan(GI:1) "{\"status\":\"done\",\"detail\":\"gi-done\"}"
$feed inject GI 1 work TOKEN client          ;# delivered, carrying a reply token
drain
check reply-on-reap 1 [expr {[llength [$feed replies]] == 1 && \
    [string match "TOKEN=*gi-done*" [lindex [$feed replies] 0]]}]
$feed destroy
$pool destroy

# ── duplicateReply: a second delivery of a live item answers via the hook ────

set pool [jobloop new 8]
$pool hold_kind work
set feed [TestFeed new "" dispatch $pool -poll 0]
$pool register work [list $feed jobWorker]
$feed admit 1
$feed inject HI 2 work "" a                   ;# first delivery, queued (held)
$feed inject HI 2 work RTOK b                 ;# second meets the live one -> dup
check dup-reply "RTOK=dup:HI:2" [lindex [$feed replies] 0]
$feed destroy
$pool destroy

# ── historyTrim keeps the newest N rows ─────────────────────────────────────

set pool [jobloop new 8]
set feed [jobfeed new "" dispatch $pool -poll 0]
$pool register work [list $feed jobWorker]
foreach id {1 2 3 4 5} { $feed enqueue TR $id work 0; drain }
check history-full 5 [dict size [$feed history]]
$feed historyTrim 2
check history-trimmed 2 [dict size [$feed history]]
check history-kept-newest {TR:4 TR:5} [dict keys [$feed history]]
$feed destroy
$pool destroy

# ── empty source: pull emits pull-skip and the heartbeat still re-arms ───────

set pool [jobloop new 8]
set feed [jobfeed new "" dispatch $pool -poll 1 -interval 60]
$pool register work [list $feed jobWorker]
set ::skips 0
$feed subscribe [list apply {{e d} { if {$e eq "pull-skip"} { incr ::skips } }}]
$feed pull
check empty-source-skip      1 $::skips
check empty-source-heartbeat 1 [expr {[$feed nextPoll] ne ""}]
$feed destroy
$pool destroy

# ── F1: a gate 'abort' cancels the launch; the item leaves Items and reruns ──

set pool [jobloop new 8]
set feed [TestFeed new "" dispatch $pool -poll 0]
$pool register work [list $feed jobWorker]
$feed abortnext
$feed enqueue MM 2 work 0
drain
check f1-abort-leaves-items "" [$feed workLive MM 2]
set ::ran {}
$feed onWorkQueue [list [dict create group MM id 2 poolkind work]]
drain
check f1-abort-reruns 1 [expr {"MM:2" in $::ran}]
$feed destroy
$pool destroy

# ── F1: a $pool cancel (the deadline recipe) reaps the item; the id reruns ───

set pool [jobloop new 8]
$pool hold_kind work
set feed [jobfeed new "" dispatch $pool -poll 0]
$pool register work [list $feed jobWorker]
$feed enqueue KK 1 work 0
drain
$pool cancel KK:1
drain
check f1-cancel-leaves-items "" [$feed workLive KK 1]
$pool release_kind work
set ::ran {}
$feed inject KK 1 work
drain
check f1-cancel-reruns 1 [expr {"KK:1" in $::ran}]
$feed destroy
$pool destroy

# ── F3: reapCore prunes the pool; an inject-only feed does not grow all_jobs ──

set pool [jobloop new 8]
set feed [jobfeed new "" dispatch $pool -poll 0]
$pool register work [list $feed jobWorker]
for {set i 1} {$i <= 12} {incr i} { $feed inject GG $i work; drain }
check f3-items-empty  0  [llength [$feed job]]
check f3-history-full 12 [dict size [$feed history]]
check f3-pool-pruned  0  [llength [$pool all_jobs]]
$feed destroy
$pool destroy

# ── F4: classifyOutcome extra cannot clobber the canonical history fields ────

set pool [jobloop new 8]
set feed [TestFeed new "" dispatch $pool -poll 0]
$pool register work [list $feed jobWorker]
$feed clobbernext
$feed enqueue AA 5 work 0
drain
set row [dict get [$feed history] AA:5]
check f4-core-status-wins done [dict get $row status]
check f4-core-id-wins      5   [dict get $row id]
check f4-extra-kept        1   [dict get $row mine]
$feed destroy
$pool destroy

# ── F5: drain (via inject) does not lift a deliberate pause_queue ────────────

set pool [jobloop new 8]
set feed [jobfeed new "" dispatch $pool -poll 0]
$pool register work [list $feed jobWorker]
$pool pause_queue
$feed inject PP 1 work                       ;# inject calls drain internally
check f5-pause-held 1 [$pool is_queue_paused]
$feed destroy
$pool destroy

# ── F6: consumer opts cannot clobber the reserved item fields ────────────────

set pool [jobloop new 8]
$pool hold_kind work
set feed [jobfeed new "" dispatch $pool -poll 0]
$pool register work [list $feed jobWorker]
$feed enqueue RR 7 work 0 [dict create group HIJACK id 999 poolkind evil mine 1]
set jr [lindex [$feed job] 0]
check f6-group-reserved    RR   [dict get $jr group]
check f6-id-reserved       7    [dict get $jr id]
check f6-poolkind-reserved work [dict get $jr poolkind]
$feed destroy
$pool destroy

if {$fails} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
