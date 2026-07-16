#!/usr/bin/env tclsh9.0
# Tests for the jobloop module: the parts bare coroutines do not give you -
# a running job cancelled or paused at its own checkpoint, a global cap with
# a per-kind sub-cap inside it, pacing floors and holds shaping which job
# launches next, a lifetime launch cap, the queue held and drained, a
# terminal job requeued, and a stale report refused. Each worker is a plain
# command in this interpreter, waiting the loop's way (an after that resumes
# the coroutine, then a yield) and reporting through the ::jobloop::worker
# verbs. The module knows nothing of the bodies.
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add $ROOT
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
# Pump the event loop until a script is true or the timeout passes.
proc wait_for {script {ms 5000}} {
    set deadline [expr {[clock milliseconds] + $ms}]
    while {[clock milliseconds] < $deadline} {
        if {[uplevel 1 $script]} { return 1 }
        set ::tick 0; after 20 {set ::tick 1}; vwait ::tick
    }
    return 0
}
proc wait_state {loop job st {ms 5000}} {
    wait_for [list expr {[$loop state $job] eq [list $st]}] $ms
}
proc wait_terminal {loop job {ms 5000}} {
    wait_for [list expr {[$loop state $job] in {done failed cancelled}}] $ms
}
proc pump {ms} { set ::t 0; after $ms {set ::t 1}; vwait ::t }
proc running_among {loop args} {
    set n 0
    foreach j $args { if {[$loop state $j] eq "running"} { incr n } }
    return $n
}
proc done_among {loop args} {
    set n 0
    foreach j $args { if {[$loop state $j] eq "done"} { incr n } }
    return $n
}

# ── the workers: commands in this interpreter, picked up from the verb
#    namespace with one path line, the way a real caller writes them. ──
namespace path ::jobloop::worker

# w_beats - wait n beats the loop's way, checkpoint between each, then a
# terminal done (with the opts result, if any).
proc w_beats {job opts} {
    set beat [expr {[dict exists $opts beat] ? [dict get $opts beat] : 30}]
    set n    [dict get $opts beats]
    for {set i 1} {$i <= $n} {incr i} {
        after $beat [info coroutine]
        yield
        checkpoint $job
    }
    if {[dict exists $opts result]} { done $job [dict get $opts result] } else { done $job }
}
proc w_error {job opts}  { after 15 [info coroutine]; yield; error "boom-$job" }
proc w_noterm {job opts} { after 15 [info coroutine]; yield }
proc w_ratelimit {job opts} {
    after 15 [info coroutine]; yield
    rate_limited $job [expr {[clock milliseconds] + 60}]
    after 60 [info coroutine]; yield
    rate_limit_cleared $job
    after 15 [info coroutine]; yield
    done $job cleared
}
# kind-named bodies (an unregistered kind runs the command of its own name)
proc heavy  {job opts} { w_beats $job $opts }
proc light  {job opts} { w_beats $job $opts }
proc paced  {job opts} { w_beats $job $opts }
proc free   {job opts} { w_beats $job $opts }
proc slow   {job opts} { w_beats $job $opts }
proc capped {job opts} { w_beats $job $opts }
proc other  {job opts} { w_beats $job $opts }
proc held   {job opts} { w_beats $job $opts }

proc new_loop {n} { return [jobloop new $n] }

# -- a job dispatches to done, its result riding job-done --------------------

set loop [new_loop 4]
set ::result none
$loop subscribe job-done {apply {{job r} {set ::result $r}}}
$loop enqueue j1 w_beats {beats 2 beat 20 result 42}
wait_terminal $loop j1
check dispatch-done done [$loop state j1]
check dispatch-result 42 $::result
$loop destroy

# -- state flips to running synchronously at enqueue, before the body runs ---

set loop [new_loop 2]
$loop enqueue j1 w_beats {beats 3 beat 40}
check sync-running running [$loop state j1]
wait_terminal $loop j1
check sync-done done [$loop state j1]
$loop destroy

# -- launched jobs progress together on the one event loop, not one at a time
#
# jobloop's concurrency is overlapping waits, not parallel CPU: coroutines
# share the one event loop and make progress together once launched. Four
# jobs each park on a 2s wait; wall time should land near one wait
# (overlapped), not four (serial) - a body or a walk that blocked the loop
# would fail the bound.

set loop [new_loop 4]
set t0 [clock milliseconds]
foreach j {o1 o2 o3 o4} { $loop enqueue $j w_beats {beats 1 beat 2000} }
foreach j {o1 o2 o3 o4} { wait_terminal $loop $j 6000 }
set elapsed [expr {[clock milliseconds] - $t0}]
check overlap-all-done 4 [done_among $loop o1 o2 o3 o4]
check overlap-concurrent 1 [expr {$elapsed < 3500}]
$loop destroy

# -- the global cap holds: 4 jobs, 2 slots, 2 running ------------------------

set loop [new_loop 2]
foreach j {a b c d} { $loop enqueue $j w_beats {beats 6 beat 30} }
check cap-running 2 [running_among $loop a b c d]
check cap-queued 2 [llength [$loop queued_jobs]]
foreach j {a b c d} { wait_terminal $loop $j }
check cap-all-done 4 [done_among $loop a b c d]
$loop destroy

# -- the pool stays full while work remains; a freed slot refills at once ----
#
# Regression guard: a partial first fill, or a walk that only refills once
# per wave instead of the instant a slot frees, starves the queue toward
# serial. Twelve jobs over four slots: the first fill must post exactly
# four, and the active count must never dip below four while jobs still
# wait, all the way to drain.

set JOBS  4
set NROWS 12
set loop [new_loop $JOBS]
$loop pause_queue
for {set i 1} {$i <= $NROWS} {incr i} {
    $loop enqueue f$i w_beats {beats 1 beat 300}
}
$loop resume_queue
check fill-first-wave $JOBS [llength [$loop active_jobs]]
check fill-rest-queued [expr {$NROWS - $JOBS}] [llength [$loop queued_jobs]]

set ::saw_below_cap 0
set t0 [clock milliseconds]
while {[done_among $loop {*}[$loop all_jobs]] < $NROWS} {
    set posted [llength [$loop active_jobs]]
    set queued [llength [$loop queued_jobs]]
    if {$queued > 0 && $posted < $JOBS} { set ::saw_below_cap 1 }
    if {[clock milliseconds] - $t0 > 10000} break
    pump 30
}
check fill-stays-full 0 $::saw_below_cap
check fill-all-done $NROWS [done_among $loop {*}[$loop all_jobs]]
$loop destroy

# -- a per-kind cap serialises one kind while another fans out ---------------

set loop [new_loop 4]
$loop set_kind_cap heavy 1
foreach j {h1 h2 h3} { $loop enqueue $j heavy {beats 6 beat 30} }
foreach j {l1 l2}    { $loop enqueue $j light {beats 6 beat 30} }
check kindcap-heavy 1 [running_among $loop h1 h2 h3]
check kindcap-light 2 [running_among $loop l1 l2]
foreach j {h1 h2 h3 l1 l2} { wait_terminal $loop $j }
$loop destroy

# -- count_by_kind counts terminal jobs by kind and state --------------------

set loop [new_loop 4]
$loop enqueue a1 heavy {beats 1 beat 20}
$loop enqueue a2 heavy {beats 1 beat 20}
$loop enqueue b1 light {beats 1 beat 20}
$loop enqueue b2 light {beats 1 beat 20}
$loop enqueue b3 light {beats 1 beat 20}
foreach j {a1 a2 b1 b2 b3} { wait_terminal $loop $j }
check countbykind-heavy-done 2 [$loop count_by_kind heavy done]
check countbykind-light-done 3 [$loop count_by_kind light done]
check countbykind-heavy-failed 0 [$loop count_by_kind heavy failed]
$loop destroy

# -- active_jobs holds only launched, non-terminal jobs -----------------------

set loop [new_loop 4]
$loop enqueue j1 w_beats {beats 1 beat 20}
$loop enqueue j2 w_beats {beats 1 beat 20}
$loop enqueue j3 w_beats {beats 40 beat 25}
wait_terminal $loop j1
wait_terminal $loop j2
set active [$loop active_jobs]
check activejobs-excludes-terminal 1 [llength $active]
check activejobs-only-running j3 [lindex $active 0]
$loop cancel j3; wait_terminal $loop j3
$loop destroy

# -- a running job is cancelled at a checkpoint mid-body ---------------------

set loop [new_loop 1]
$loop enqueue j1 w_beats {beats 40 beat 25}
wait_state $loop j1 running
$loop cancel j1
wait_terminal $loop j1
check cancel-running cancelled [$loop state j1]
$loop destroy

# -- a queued job cancels in place, before it ever launches ------------------

set loop [new_loop 1]
$loop enqueue j1 w_beats {beats 40 beat 30}
$loop enqueue j2 w_beats {beats 2 beat 20}
wait_state $loop j1 running
check queued-behind queued [$loop state j2]
$loop cancel j2
check cancel-queued cancelled [$loop state j2]
$loop cancel j1; wait_terminal $loop j1
$loop destroy

# -- a running job is paused at a checkpoint (parked coroutine) then resumed -

set loop [new_loop 1]
$loop enqueue j1 w_beats {beats 40 beat 25}
wait_state $loop j1 running
$loop pause_job j1
wait_state $loop j1 paused
check pause-paused paused [$loop state j1]
$loop resume_job j1
wait_state $loop j1 running
check resume-running running [$loop state j1]
$loop cancel j1; wait_terminal $loop j1
$loop destroy

# -- cancelling a paused job resumes it into the post-pause cancel check -----

set loop [new_loop 1]
$loop enqueue j1 w_beats {beats 40 beat 25}
wait_state $loop j1 running
$loop pause_job j1
wait_state $loop j1 paused
$loop cancel j1
wait_terminal $loop j1
check cancel-breaks-pause cancelled [$loop state j1]
$loop destroy

# -- a worker held on an external limit occupies its slot, then clears -------

set loop [new_loop 1]
set ::rl_until ""
$loop subscribe job-rate-limited {apply {{job until} {set ::rl_until $until}}}
$loop enqueue j1 w_ratelimit {}
wait_state $loop j1 rate_limited
check rl-state rate_limited [$loop state j1]
check rl-holds-slot 1 [llength [$loop active_jobs]]
check rl-payload 1 [expr {$::rl_until ne ""}]
wait_terminal $loop j1
check rl-cleared-done done [$loop state j1]
$loop destroy

# -- the whole queue holds, then drains --------------------------------------

set loop [new_loop 2]
$loop pause_queue
foreach j {a b c} { $loop enqueue $j w_beats {beats 2 beat 20} }
pump 60
check queue-held 3 [llength [$loop queued_jobs]]
check queue-paused-flag 1 [$loop is_queue_paused]
$loop resume_queue
foreach j {a b c} { wait_terminal $loop $j }
check queue-drained 3 [done_among $loop a b c]
$loop destroy

# -- the pacing floor spaces a kind; an unpaced kind is undelayed ------------

set loop [new_loop 4]
$loop set_kind_pace paced 300
set ::launch_at [dict create]
$loop subscribe job-state {apply {{job st} {
    if {$st eq "running"} { dict set ::launch_at $job [clock milliseconds] }
}}}
$loop enqueue p1 paced {beats 1 beat 10}
$loop enqueue p2 paced {beats 1 beat 10}
$loop enqueue u1 free  {beats 1 beat 10}
$loop enqueue u2 free  {beats 1 beat 10}
# p1 launches now; p2 waits for the floor; u1/u2 (kind free) launch at once.
check pace-p2-waits queued [$loop state p2]
check pace-u1-now 1 [expr {[dict exists $::launch_at u1]}]
check pace-u2-now 1 [expr {[dict exists $::launch_at u2]}]
check pace-u1-undelayed 1 \
    [expr {[dict get $::launch_at u1] - [dict get $::launch_at p1] < 120}]
wait_state $loop p2 running 2000
set gap [expr {[dict get $::launch_at p2] - [dict get $::launch_at p1]}]
check pace-floor-honoured 1 [expr {$gap >= 280}]
foreach j {p1 p2 u1 u2} { wait_terminal $loop $j }
$loop destroy

# -- hold_kind announces once, keeps the kind back, release drains -----------

set loop [new_loop 4]
set ::hev {}
$loop subscribe kind-held    {apply {{kind} {lappend ::hev held:$kind}}}
$loop subscribe kind-released {apply {{kind} {lappend ::hev released:$kind}}}
$loop hold_kind slow
foreach j {s1 s2 s3} { $loop enqueue $j slow {beats 2 beat 20} }
pump 60
check hold-none-running 0 [running_among $loop s1 s2 s3]
check hold-is-held 1 [$loop is_kind_held slow]
check hold-announce-once 1 [llength [lsearch -all $::hev held:slow]]
$loop release_kind slow
check hold-released 1 [expr {"released:slow" in $::hev}]
check hold-not-held 0 [$loop is_kind_held slow]
foreach j {s1 s2 s3} { wait_terminal $loop $j }
check hold-drained 3 [done_among $loop s1 s2 s3]
$loop destroy

# -- the count cap launches exactly n, and fires its event once --------------

set loop [new_loop 4]
set ::cc 0
$loop subscribe count-cap-reached {apply {{} {incr ::cc}}}
$loop set_count_cap 2
foreach j {a b c d} { $loop enqueue $j w_beats {beats 2 beat 25} }
wait_terminal $loop a
wait_terminal $loop b
check countcap-launched 2 [$loop launched_count]
check countcap-event-once 1 $::cc
check countcap-c-held queued [$loop state c]
check countcap-d-held queued [$loop state d]
$loop destroy

# -- a terminal job is requeued and runs again -------------------------------

set loop [new_loop 1]
$loop enqueue j1 w_beats {beats 1 beat 20 result first}
wait_terminal $loop j1
check requeue-first done [$loop state j1]
$loop requeue j1
wait_terminal $loop j1
check requeue-again done [$loop state j1]
$loop destroy

# -- prune_missing drops jobs outside a keep-set, spares the active ----------

set loop [new_loop 1]
$loop enqueue a w_beats {beats 40 beat 30}   ;# runs (holds the one slot)
$loop enqueue b w_beats {beats 40 beat 30}   ;# queued, in the keep-set
$loop enqueue c w_beats {beats 40 beat 30}   ;# queued, not in the keep-set
wait_state $loop a running
check prune-count 1 [$loop prune_missing {a b}]
check prune-dropped "" [$loop state c]
check prune-kept-queued queued [$loop state b]
check prune-kept-active running [$loop state a]
$loop cancel b; $loop cancel a; wait_terminal $loop a
$loop destroy

# -- register remaps a kind to a body of another name ------------------------

set loop [new_loop 1]
$loop register special w_beats
$loop enqueue j1 special {beats 1 beat 20 result reg-ok}
wait_terminal $loop j1
check register-done done [$loop state j1]
check register-kind special [$loop kind_of j1]
$loop destroy

# -- an admission gate aborts one job and admits the rest --------------------

set loop [new_loop 2]
$loop pause_queue
$loop set_pre_launch_callback {apply {{job kind idx total} {
    expr {$job eq "skip" ? "abort" : ""}
}}}
$loop enqueue keep w_beats {beats 1 beat 20}
$loop enqueue skip w_beats {beats 1 beat 20}
$loop resume_queue
check gate-aborted cancelled [$loop state skip]
wait_terminal $loop keep
check gate-admitted done [$loop state keep]
$loop destroy

# -- the gate defers a job: queued, not cancelled, launched once admitted ----

set loop [new_loop 2]
set ::admit_d 0
$loop set_pre_launch_callback {apply {{job kind idx total} {
    expr {$job eq "d1" && !$::admit_d ? "defer" : ""}
}}}
$loop enqueue d1 w_beats {beats 2 beat 20}
pump 40
check defer-queued 1 [expr {"d1" in [$loop queued_jobs]}]
check defer-not-cancelled queued [$loop state d1]
set ::admit_d 1
$loop enqueue t1 w_beats {beats 1 beat 20}   ;# this walk reconsiders d1
wait_terminal $loop d1
check defer-launched done [$loop state d1]
$loop destroy

# -- defer and abort part ways: one waits, one dies, the third runs ----------

set loop [new_loop 3]
$loop set_pre_launch_callback {apply {{job kind idx total} {
    switch -- $job {drop {return abort} hold {return defer} default {return ""}}
}}}
$loop enqueue drop w_beats {beats 1 beat 20}
$loop enqueue hold w_beats {beats 1 beat 20}
$loop enqueue go   w_beats {beats 1 beat 20}
pump 50
check dva-abort-cancelled cancelled [$loop state drop]
check dva-defer-queued queued [$loop state hold]
check dva-admit-launched 1 [expr {[$loop state go] ni {queued cancelled}}]
$loop destroy

# -- a later high-priority job jumps ahead of earlier same-kind queued work --

set loop [new_loop 1]
$loop enqueue lo1 heavy {beats 2 beat 20}            ;# runs, finishes soon
$loop enqueue lo2 heavy {beats 20 beat 25}           ;# queued
$loop enqueue hi  heavy {beats 20 beat 25} -priority 5
wait_state $loop lo1 running
wait_state $loop hi running 3000   ;# lo1 done -> the walk takes hi before lo2
check prio-hi-first running [$loop state hi]
check prio-lo2-waits queued [$loop state lo2]
$loop cancel hi; $loop cancel lo2; wait_terminal $loop hi
$loop destroy

# -- within one priority level the queue stays first-in first-out ------------

set loop [new_loop 1]
$loop enqueue lo1 heavy {beats 2 beat 20}
$loop enqueue a heavy {beats 20 beat 25} -priority 3
$loop enqueue b heavy {beats 20 beat 25} -priority 3
wait_state $loop lo1 running
wait_state $loop a running 3000
check fifo-a-first running [$loop state a]
check fifo-b-waits queued [$loop state b]
$loop cancel a; $loop cancel b; wait_terminal $loop a
$loop destroy

# -- priority does not override the kind cap ---------------------------------

set loop [new_loop 3]
$loop set_kind_cap capped 1
$loop enqueue c1  capped {beats 20 beat 25}
$loop enqueue chi capped {beats 20 beat 25} -priority 9
$loop enqueue o1  other  {beats 20 beat 25}
$loop enqueue o2  other  {beats 20 beat 25}
wait_state $loop c1 running
pump 60
check prio-kindcap-held queued [$loop state chi]
check prio-kindcap-others 2 [running_among $loop o1 o2]
$loop cancel chi; $loop cancel o1; $loop cancel o2; $loop cancel c1
wait_terminal $loop c1
$loop destroy

# -- priority does not override a hold ---------------------------------------

set loop [new_loop 3]
$loop hold_kind held
$loop enqueue hhi held  {beats 20 beat 25} -priority 9
$loop enqueue o1  other {beats 20 beat 25}
$loop enqueue o2  other {beats 20 beat 25}
pump 60
check prio-hold-held queued [$loop state hhi]
check prio-hold-others 2 [running_among $loop o1 o2]
$loop release_kind held
wait_state $loop hhi running 2000
check prio-hold-released running [$loop state hhi]
$loop cancel hhi; $loop cancel o1; $loop cancel o2
wait_terminal $loop hhi
$loop destroy

# -- an uncaught error lands the job failed, its message the reason ----------

set loop [new_loop 1]
set ::fail_reason ""
$loop subscribe job-failed {apply {{job r} {set ::fail_reason $r}}}
$loop enqueue j1 w_error {}
$loop enqueue j2 w_beats {beats 1 beat 20}
wait_terminal $loop j1
check error-failed failed [$loop state j1]
check error-message 1 [string match *boom-j1* $::fail_reason]
# j2 was queued behind j1 (pool of one); it must now run to completion -
# proof the slot is genuinely free, not just relabelled.
wait_terminal $loop j2
check error-frees-slot done [$loop state j2]
$loop destroy

# -- a body that returns with no terminal verb lands done, empty result ------

set loop [new_loop 1]
set ::done_result none
$loop subscribe job-done {apply {{job r} {set ::done_result $r}}}
$loop enqueue j1 w_noterm {}
wait_terminal $loop j1
check noterm-done done [$loop state j1]
check noterm-empty "" $::done_result
$loop destroy

# -- a report for a job that was never enqueued is refused -------------------

set ::logged2 {}
set loop [jobloop new 1 -log [list apply {{acc msg} {lappend ::logged2 $msg}} logged2]]
$loop on_phase ghost somephase
check stale-unknown 1 [string match "*phase for unknown job ghost*" $::logged2]
$loop destroy

# -- a report that does not fit the job's current state is refused, the
#    state left untouched ----------------------------------------------------

set ::logged3 {}
set loop [jobloop new 1 -log [list apply {{acc msg} {lappend ::logged3 $msg}} logged3]]
$loop pause_queue
$loop enqueue j1 w_beats {beats 1 beat 20}
$loop on_done j1 too-early
check stale-wrong-state 1 [string match "*done for job j1 in state queued*" $::logged3]
check stale-state-unchanged queued [$loop state j1]
$loop resume_queue
wait_terminal $loop j1
$loop destroy

# -- a duplicate enqueue is dropped with a diagnostic ------------------------

set ::logged {}
set loop [jobloop new 1 -log [list apply {{acc msg} {lappend ::logged $msg}} logged]]
$loop enqueue j1 w_beats {beats 40 beat 30}
$loop enqueue j1 w_beats {beats 1 beat 10}
check dup-dropped 1 [string match "*already present*" $::logged]
$loop cancel j1; wait_terminal $loop j1
$loop destroy

# -- destroy with live parked coroutines leaves no commands, no stray timers -

set loop [new_loop 2]
$loop enqueue a w_beats {beats 60 beat 25}
$loop enqueue b w_beats {beats 60 beat 25}
wait_state $loop a running
wait_state $loop b running
$loop pause_job a
$loop pause_job b
wait_state $loop a paused
wait_state $loop b paused
set ns [info object namespace $loop]
check destroy-coros-parked 2 [llength [info commands ${ns}::co*]]
# no pending timer names this pool's namespace before or after the teardown
proc strays_naming {ns} {
    set n 0
    foreach id [after info] {
        if {[string match "*$ns*" [lindex [after info $id] 0]]} { incr n }
    }
    return $n
}
$loop destroy
check destroy-ns-empty 0 [llength [info commands ${ns}::*]]
check destroy-no-stray-timers 0 [strays_naming $ns]

puts "----"
if {$fails} { puts "FAILED ($fails)" } else { puts PASS }
exit $fails
