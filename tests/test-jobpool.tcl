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
check cap-posted 2 [$p posted_count]
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
check held-holds-slot 1 [$p posted_count]
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
$p set_pre_post_callback {apply {{job kind idx total} {
    expr {$job eq "skip" ? "abort" : ""}
}}}
$p enqueue keep fake_worker {plan {{sleep 20}}}
$p enqueue skip fake_worker {plan {{sleep 20}}}
$p resume_queue
check gate-aborted cancelled [$p state skip]
wait_terminal $p keep 2000
check gate-admitted done [$p state keep]
$p destroy

# -- a message for an unknown job is refused, not obeyed ----------------------

set logged {}
set p [jobpool new 1 -init $WORKER -log [list apply {{acc msg} {
    lappend ::logged $msg
}} logged]]
$p on_phase ghost somephase
check stale-refused 1 [expr {[string match "*phase for unknown job ghost*" $logged]}]
$p destroy

puts "----"
if {$fails} { puts "FAILED ($fails)" } else { puts PASS }
exit $fails
