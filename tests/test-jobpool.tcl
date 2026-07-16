#!/usr/bin/env tclsh9.0
# Tests for the jobpool module: the parts a plain tpool cannot do - a
# running job cancelled and paused through its sentinel, a per-kind cap
# inside the global one, the queue held and drained, a terminal job
# requeued, and a stale message refused. The worker here is a scripted
# stand-in defined in the pool's own init; the module knows nothing of it.
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add $ROOT
package require jobpool

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
proc wait_state {pool job st {ms 5000}} {
    set deadline [expr {[clock milliseconds] + $ms}]
    while {[clock milliseconds] < $deadline} {
        if {[$pool state $job] eq $st} { return 1 }
        set ::tick 0; after 20 {set ::tick 1}; vwait ::tick
    }
    return 0
}
proc wait_terminal {pool job {ms 5000}} {
    wait_for [list expr {[$pool state $job] in {done failed cancelled}}] $ms
}
proc pump {ms} { set ::t 0; after $ms {set ::t 1}; vwait ::t }
proc running_among {pool args} {
    set n 0
    foreach j $args { if {[$pool state $j] eq "running"} { incr n } }
    return $n
}
proc done_among {pool args} {
    set n 0
    foreach j $args { if {[$pool state $j] eq "done"} { incr n } }
    return $n
}

# The worker: run a scripted plan of steps, checking its sentinels at the
# points the plan names, and message the pool as it goes.
set WORKER {
    proc jp_cancelled? {job} { return [tsv::exists $::jobpool_tsv $job.cancel] }
    proc jp_paused? {job}    { return [tsv::exists $::jobpool_tsv $job.pause] }
    proc jp_msg {name args} {
        thread::send -async $::main_tid [list $::pool $name {*}$args]
    }
    proc heavy   {job opts} { fake_worker $job $opts }
    proc light {job opts} { fake_worker $job $opts }
    proc paced {job opts} { fake_worker $job $opts }
    proc free  {job opts} { fake_worker $job $opts }
    proc capped {job opts} { fake_worker $job $opts }
    proc other  {job opts} { fake_worker $job $opts }
    proc held   {job opts} { fake_worker $job $opts }
    proc fake_worker {job opts} {
        foreach step [dict get $opts plan] {
            switch -- [lindex $step 0] {
                sleep { after [lindex $step 1] }
                fail  { jp_msg on_failed $job [lindex $step 1]; return }
                check_cancel {
                    if {[jp_cancelled? $job]} { jp_msg on_cancelled $job; return }
                }
                check_pause {
                    if {[jp_paused? $job]} {
                        jp_msg on_paused $job
                        while {[jp_paused? $job]} { after 20 }
                        jp_msg on_resumed $job
                    }
                }
                hold {
                    jp_msg on_rate_limited $job [lindex $step 1]
                    after [lindex $step 2]
                    jp_msg on_rate_limit_cleared $job
                }
            }
        }
        jp_msg on_done $job
    }
    # Bodies written the intended way: the pool seeds the worker verbs, a
    # `namespace path` line picks them up, and the body reports through
    # them instead of hand-rolling thread::send. checkpoint reads the
    # sentinels the verbs share with the pool.
    namespace path ::jobpool::worker
    proc vbeats {job opts} {
        set beat [expr {[dict exists $opts beat] ? [dict get $opts beat] : 30}]
        for {set i 0} {$i < [dict get $opts beats]} {incr i} {
            after $beat
            checkpoint $job
        }
        if {[dict exists $opts result]} { done $job [dict get $opts result] } else { done $job }
    }
    proc vphase  {job opts} { phase $job started; after 20; done $job ok }
    proc verror  {job opts} { after 20; error "boom-$job" }
    proc vnoterm {job opts} { after 20 }
    # enters rate_limited and stays there, polling its cancel sentinel at a
    # checkpoint through the wait so a cancel can land while it holds a slot.
    proc rlhold {job opts} {
        after 15
        rate_limited $job [expr {[clock milliseconds] + 10000}]
        for {set i 0} {$i < 400} {incr i} {
            after 15
            checkpoint $job
        }
        rate_limit_cleared $job
        done $job cleared
    }
}
proc new_pool {jobs} { return [jobpool new $jobs -init $::WORKER] }

# -- a job runs to done -------------------------------------------------------

set p [new_pool 4]
$p enqueue r1 fake_worker {plan {{sleep 30}}}
check dispatch-running running [$p state r1]
wait_terminal $p r1 3000
check dispatch-done done [$p state r1]
$p destroy

# -- the global cap holds: 4 jobs, 2 slots, 2 posted --------------------------

set p [new_pool 2]
foreach r {r1 r2 r3 r4} { $p enqueue $r fake_worker {plan {{sleep 200}}} }
check cap-posted 2 [llength [$p active_jobs]]
check cap-queued 2 [llength [$p queued_jobs]]
foreach r {r1 r2 r3 r4} { wait_terminal $p $r 6000 }
check cap-all-done 4 [llength [lmap r {r1 r2 r3 r4} {expr {[$p state $r] eq "done" ? $r : [continue]}}]]
$p destroy

# -- a per-kind cap serialises one kind while another fans out ----------------

set p [new_pool 4]
$p set_kind_cap heavy 1
foreach r {h1 h2 h3} { $p enqueue $r heavy {plan {{sleep 300}}} }
foreach r {l1 l2} { $p enqueue $r light {plan {{sleep 300}}} }
# heavy held to one active; light fills the rest of the 4 slots.
check kind-cap-heavy 1 [llength [lmap r {h1 h2 h3} {expr {[$p state $r] eq "running" ? $r : [continue]}}]]
check kind-cap-light 2 [llength [lmap r {l1 l2} {expr {[$p state $r] eq "running" ? $r : [continue]}}]]
foreach r {h1 h2 h3 l1 l2} { wait_terminal $p $r 8000 }
$p destroy

# -- a running job is cancelled through its sentinel --------------------------

set p [new_pool 1]
$p enqueue r1 fake_worker \
    {plan {{sleep 40} {check_cancel} {sleep 40} {check_cancel}}}
wait_state $p r1 running 1000
$p cancel r1
wait_terminal $p r1 2000
check cancel-running cancelled [$p state r1]
$p destroy

# -- a queued job cancels in place, before it ever posts ----------------------

set p [new_pool 1]
$p enqueue r1 fake_worker {plan {{sleep 300}}}
$p enqueue r2 fake_worker {plan {{sleep 30}}}
wait_state $p r1 running 1000
check queued-behind queued [$p state r2]
$p cancel r2
check cancel-queued cancelled [$p state r2]
wait_terminal $p r1 1000
$p destroy

# -- a running job is paused and resumed through its sentinel ------------------

set p [new_pool 1]
$p enqueue r1 fake_worker {plan {{sleep 40} {check_pause} {sleep 30}}}
wait_state $p r1 running 1000
$p pause_job r1
wait_state $p r1 paused 2000
check pause-running paused [$p state r1]
$p resume_job r1
wait_terminal $p r1 2000
check resume-done done [$p state r1]
$p destroy

# -- the whole queue holds, then drains ---------------------------------------

set p [new_pool 2]
$p pause_queue
foreach r {r1 r2 r3} { $p enqueue $r fake_worker {plan {{sleep 30}}} }
set ::tick 0; after 50 {set ::tick 1}; vwait ::tick
check queue-held 3 [llength [$p queued_jobs]]
$p resume_queue
foreach r {r1 r2 r3} { wait_terminal $p $r 3000 }
check queue-drained 3 [llength [lmap r {r1 r2 r3} {expr {[$p state $r] eq "done" ? $r : [continue]}}]]
$p destroy

# -- a worker held on an external limit occupies its slot, then clears --------

set p [new_pool 1]
$p enqueue r1 fake_worker {plan {{sleep 20} {hold 5 120} {sleep 20}}}
wait_state $p r1 rate_limited 1000
check held-state rate_limited [$p state r1]
check held-holds-slot 1 [llength [$p active_jobs]]
wait_terminal $p r1 2000
check held-cleared-done done [$p state r1]
$p destroy

# -- a terminal job is requeued and runs again --------------------------------

set p [new_pool 1]
$p enqueue r1 fake_worker {plan {{sleep 20}}}
wait_terminal $p r1 2000
check requeue-first done [$p state r1]
$p requeue r1
wait_terminal $p r1 2000
check requeue-again done [$p state r1]
$p destroy

# -- prune_missing drops jobs outside a keep-set, spares the active ----------

set p [new_pool 1]
$p enqueue a fake_worker {plan {{sleep 20}}}    ;# runs (holds the one slot)
$p enqueue b fake_worker {plan {{sleep 300}}}   ;# queued, in the keep-set
$p enqueue c fake_worker {plan {{sleep 300}}}   ;# queued, not in the keep-set
wait_state $p a running 1000
check prune-count 1 [$p prune_missing {a b}]
check prune-dropped "" [$p state c]
check prune-kept-queued queued [$p state b]
check prune-kept-active running [$p state a]
$p cancel b; wait_terminal $p a 2000
$p destroy

# -- a pre-post gate aborts one job and admits the rest ----------------------

set p [new_pool 2]
$p pause_queue
$p set_pre_launch_callback {apply {{job kind} {
    expr {$job eq "skip" ? "abort" : ""}
}}}
$p enqueue keep fake_worker {plan {{sleep 20}}}
$p enqueue skip fake_worker {plan {{sleep 20}}}
$p resume_queue
check gate-aborted cancelled [$p state skip]
wait_terminal $p keep 2000
check gate-admitted done [$p state keep]
$p destroy

# -- the gate defers a job: queued, not cancelled, posted once admitted ------

set p [new_pool 2]
set ::admit_d 0
$p set_pre_launch_callback {apply {{job kind} {
    expr {$job eq "d1" && !$::admit_d ? "defer" : ""}
}}}
$p enqueue d1 fake_worker {plan {{sleep 20}}}
pump 40
check defer-queued 1 [expr {"d1" in [$p queued_jobs]}]
check defer-not-cancelled queued [$p state d1]
set ::admit_d 1
$p enqueue t1 fake_worker {plan {{sleep 20}}}   ;# this walk reconsiders d1
wait_terminal $p d1
check defer-launched done [$p state d1]
$p destroy

# -- defer and abort part ways: one waits, one dies, the third runs ----------

set p [new_pool 3]
$p set_pre_launch_callback {apply {{job kind} {
    switch -- $job {drop {return abort} hold {return defer} default {return ""}}
}}}
$p enqueue drop fake_worker {plan {{sleep 20}}}
$p enqueue hold fake_worker {plan {{sleep 20}}}
$p enqueue go   fake_worker {plan {{sleep 20}}}
pump 60
check dva-abort-cancelled cancelled [$p state drop]
check dva-defer-queued queued [$p state hold]
check dva-admit-launched 1 [expr {[$p state go] ni {queued cancelled}}]
$p destroy

# -- a later high-priority job jumps ahead of earlier same-kind queued work --

set p [new_pool 1]
$p enqueue lo1 heavy {plan {{sleep 40}}}             ;# runs, finishes soon
$p enqueue lo2 heavy {plan {{sleep 150}}}            ;# queued
$p enqueue hi  heavy {plan {{sleep 150}}} -priority 5
wait_state $p lo1 running
wait_state $p hi running 3000   ;# lo1 done -> the walk takes hi before lo2
check prio-hi-first running [$p state hi]
check prio-lo2-waits queued [$p state lo2]
$p cancel lo2; wait_terminal $p hi 2000
$p destroy

# -- within one priority level the queue stays first-in first-out ------------

set p [new_pool 1]
$p enqueue lo1 heavy {plan {{sleep 40}}}
$p enqueue a heavy {plan {{sleep 150}}} -priority 3
$p enqueue b heavy {plan {{sleep 150}}} -priority 3
wait_state $p lo1 running
wait_state $p a running 3000
check fifo-a-first running [$p state a]
check fifo-b-waits queued [$p state b]
$p cancel b; wait_terminal $p a 2000
$p destroy

# -- priority does not override the kind cap ---------------------------------

set p [new_pool 3]
$p set_kind_cap capped 1
$p enqueue c1  capped {plan {{sleep 200}}}
$p enqueue chi capped {plan {{sleep 200}}} -priority 9
$p enqueue o1  other  {plan {{sleep 200}}}
$p enqueue o2  other  {plan {{sleep 200}}}
wait_state $p c1 running
pump 60
check prio-kindcap-held queued [$p state chi]
check prio-kindcap-others 2 [running_among $p o1 o2]
$p cancel chi
foreach j {c1 o1 o2} { wait_terminal $p $j 3000 }
$p destroy

# -- priority does not override a hold ---------------------------------------

set p [new_pool 3]
$p hold_kind held
$p enqueue hhi held  {plan {{sleep 200}}} -priority 9
$p enqueue o1  other {plan {{sleep 200}}}
$p enqueue o2  other {plan {{sleep 200}}}
pump 60
check prio-hold-held queued [$p state hhi]
check prio-hold-others 2 [running_among $p o1 o2]
$p release_kind held
wait_state $p hhi running 2000
check prio-hold-released running [$p state hhi]
$p cancel hhi
foreach j {o1 o2 hhi} { wait_terminal $p $j 3000 }
$p destroy

# -- the pacing floor spaces a kind; an unpaced kind is undelayed ------------

set p [new_pool 4]
$p set_kind_pace paced 300
set ::plaunch [dict create]
$p subscribe job-state {apply {{job st} {
    if {$st eq "running"} { dict set ::plaunch $job [clock milliseconds] }
}}}
$p enqueue p1 paced {plan {{sleep 20}}}
$p enqueue p2 paced {plan {{sleep 20}}}
$p enqueue u1 free  {plan {{sleep 20}}}
$p enqueue u2 free  {plan {{sleep 20}}}
check pace-p2-waits queued [$p state p2]
check pace-u1-now running [$p state u1]
wait_state $p p2 running 2000
set gap [expr {[dict get $::plaunch p2] - [dict get $::plaunch p1]}]
check pace-floor 1 [expr {$gap >= 280}]
foreach j {p1 p2 u1 u2} { wait_terminal $p $j }
$p destroy

# -- the count cap launches exactly n, and fires its event once --------------

set p [new_pool 4]
set ::cc 0
$p subscribe count-cap-reached {apply {{} {incr ::cc}}}
$p set_count_cap 2
foreach j {a b c d} { $p enqueue $j fake_worker {plan {{sleep 25}}} }
wait_terminal $p a; wait_terminal $p b
check countcap-launched 2 [$p launched_count]
check countcap-once 1 $::cc
check countcap-c-held queued [$p state c]
$p destroy

# -- hold_kind announces once, keeps the kind back, release drains -----------

set p [new_pool 4]
set ::hev {}
$p subscribe kind-held {apply {{kind} {lappend ::hev $kind}}}
$p hold_kind heavy
foreach j {h1 h2 h3} { $p enqueue $j heavy {plan {{sleep 20}}} }
pump 60
check hold-none-running 0 [running_among $p h1 h2 h3]
check hold-is-held 1 [$p is_kind_held heavy]
check hold-announce-once 1 [llength $::hev]
$p release_kind heavy
foreach j {h1 h2 h3} { wait_terminal $p $j }
check hold-drained 3 [done_among $p h1 h2 h3]
$p destroy

# -- register remaps a kind to a proc of another name ------------------------

set p [new_pool 1]
$p register special fake_worker
$p enqueue j1 special {plan {{sleep 20}}}
wait_terminal $p j1
check register-done done [$p state j1]
check register-kind special [$p kind_of j1]
$p destroy

# -- the seeded verbs are available in a worker: namespace path + done -------

set p [new_pool 1]
set ::vph ""
$p subscribe job-phase {apply {{job name} {set ::vph $name}}}
$p enqueue j1 vphase {}
wait_terminal $p j1
check verb-done done [$p state j1]
check verb-phase started $::vph
$p destroy

# -- an uncaught error in a verb body lands the job failed -------------------

set p [new_pool 1]
set ::vfr ""
$p subscribe job-failed {apply {{job r} {set ::vfr $r}}}
$p enqueue j1 verror {}
wait_terminal $p j1
check verb-failed failed [$p state j1]
check verb-fail-msg 1 [string match *boom-j1* $::vfr]
$p destroy

# -- a verb body that returns with no terminal verb lands done, empty --------

set p [new_pool 1]
set ::vdr none
$p subscribe job-done {apply {{job r} {set ::vdr $r}}}
$p enqueue j1 vnoterm {}
wait_terminal $p j1
check verb-noterm done [$p state j1]
check verb-noterm-empty "" $::vdr
$p destroy

# -- cancelling a paused verb body breaks the pause into a cancel ------------

set p [new_pool 1]
$p enqueue j1 vbeats {beats 40 beat 25}
wait_state $p j1 running
$p pause_job j1
wait_state $p j1 paused
check verb-paused paused [$p state j1]
$p cancel j1
wait_terminal $p j1
check verb-cancel-breaks-pause cancelled [$p state j1]
$p destroy

# -- a message for an unknown job is refused, not obeyed ----------------------

set logged {}
set p [jobpool new 1 -init $WORKER -log [list apply {{acc msg} {
    lappend ::logged $msg
}} logged]]
$p on_phase ghost somephase
check stale-refused 1 [expr {[string match "*phase for unknown job ghost*" $logged]}]
$p destroy

# -- cancelling a rate_limited job frees its slot, does not strand it --------

set p [new_pool 1]
$p enqueue j1 rlhold {}
wait_state $p j1 rate_limited 3000
$p cancel j1
wait_terminal $p j1 3000
check rlcancel-cancelled cancelled [$p state j1]
check rlcancel-slot-freed 0 [llength [$p active_jobs]]
$p enqueue j2 fake_worker {plan {{sleep 20}}}   ;# the freed slot takes a new job
wait_terminal $p j2 2000
check rlcancel-slot-reused done [$p state j2]
$p destroy

# -- a verb body that reports its own done draws no fallback diagnostic ------

set ::difflog {}
set p [jobpool new 2 -init $WORKER -log [list apply {{acc m} {lappend ::difflog $m}} difflog]]
$p enqueue j1 vbeats {beats 1 beat 15 result r1}
$p enqueue j2 vbeats {beats 1 beat 15 result r2}
wait_terminal $p j1 2000
wait_terminal $p j2 2000
check nodiag-both-done 2 [done_among $p j1 j2]
check nodiag-zero-log 0 [llength $::difflog]
$p destroy

puts "----"
if {$fails} { puts "FAILED ($fails)" } else { puts PASS }
exit $fails
