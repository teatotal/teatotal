#!/usr/bin/env tclsh9.0
# Tests for the jobpool module: the parts a plain tpool cannot do - a
# running job cancelled and paused through its sentinel, a per-kind cap
# inside the global one, the queue held and drained, a terminal row
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
proc wait_state {pool row st {ms 5000}} {
    set deadline [expr {[clock milliseconds] + $ms}]
    while {[clock milliseconds] < $deadline} {
        if {[$pool state $row] eq $st} { return 1 }
        set ::tick 0; after 20 {set ::tick 1}; vwait ::tick
    }
    return 0
}
proc wait_terminal {pool row {ms 5000}} {
    wait_for [list expr {[$pool state $row] in {done failed cancelled}}] $ms
}

# The worker: run a scripted plan of steps, checking its sentinels at the
# points the plan names, and message the pool as it goes.
set WORKER {
    proc jp_cancelled? {row} { return [tsv::exists $::jobpool_tsv $row.cancel] }
    proc jp_paused? {row}    { return [tsv::exists $::jobpool_tsv $row.pause] }
    proc jp_msg {name args} {
        thread::send -async $::main_tid [list $::dispatcher $name {*}$args]
    }
    proc upload   {row opts} { fake_worker $row $opts }
    proc download {row opts} { fake_worker $row $opts }
    proc fake_worker {row opts} {
        foreach step [dict get $opts plan] {
            switch -- [lindex $step 0] {
                sleep { after [lindex $step 1] }
                fail  { jp_msg on_failed $row [lindex $step 1]; return }
                check_cancel {
                    if {[jp_cancelled? $row]} { jp_msg on_cancelled $row; return }
                }
                check_pause {
                    if {[jp_paused? $row]} {
                        jp_msg on_paused $row
                        while {[jp_paused? $row]} { after 20 }
                        jp_msg on_resumed $row
                    }
                }
            }
        }
        jp_msg on_done $row
    }
}
proc new_pool {jobs} { return [jobpool new $jobs -init $::WORKER] }

# -- a job runs to done -------------------------------------------------------

set p [new_pool 4]
$p enqueue r1 render fake_worker {plan {{sleep 30}}}
check dispatch-running running [$p state r1]
wait_terminal $p r1 3000
check dispatch-done done [$p state r1]
$p destroy

# -- the global cap holds: 4 jobs, 2 slots, 2 posted --------------------------

set p [new_pool 2]
foreach r {r1 r2 r3 r4} { $p enqueue $r render fake_worker {plan {{sleep 200}}} }
check cap-posted 2 [$p posted_count]
check cap-queued 2 [llength [$p queued_rows]]
foreach r {r1 r2 r3 r4} { wait_terminal $p $r 6000 }
check cap-all-done 4 [llength [lmap r {r1 r2 r3 r4} {expr {[$p state $r] eq "done" ? $r : [continue]}}]]
$p destroy

# -- a per-kind cap serialises one kind while another fans out ----------------

set p [new_pool 4]
$p set_worker_cap upload 1
foreach r {u1 u2 u3} { $p enqueue $r batch upload {plan {{sleep 300}}} }
foreach r {d1 d2} { $p enqueue $r batch download {plan {{sleep 300}}} }
# uploads capped at 1 active; downloads fill the rest of the 4 slots.
check kind-cap-uploads 1 [llength [lmap r {u1 u2 u3} {expr {[$p state $r] eq "running" ? $r : [continue]}}]]
check kind-cap-downloads 2 [llength [lmap r {d1 d2} {expr {[$p state $r] eq "running" ? $r : [continue]}}]]
foreach r {u1 u2 u3 d1 d2} { wait_terminal $p $r 8000 }
$p destroy

# -- a running job is cancelled through its sentinel --------------------------

set p [new_pool 1]
$p enqueue r1 render fake_worker \
    {plan {{sleep 40} {check_cancel} {sleep 40} {check_cancel}}}
wait_state $p r1 running 1000
$p cancel r1
wait_terminal $p r1 2000
check cancel-running cancelled [$p state r1]
$p destroy

# -- a queued job cancels in place, before it ever posts ----------------------

set p [new_pool 1]
$p enqueue r1 render fake_worker {plan {{sleep 300}}}
$p enqueue r2 render fake_worker {plan {{sleep 30}}}
wait_state $p r1 running 1000
check queued-behind queued [$p state r2]
$p cancel r2
check cancel-queued cancelled [$p state r2]
wait_terminal $p r1 1000
$p destroy

# -- a running job is paused and resumed through its sentinel ------------------

set p [new_pool 1]
$p enqueue r1 render fake_worker {plan {{sleep 40} {check_pause} {sleep 30}}}
wait_state $p r1 running 1000
$p pause_row r1
wait_state $p r1 paused 2000
check pause-running paused [$p state r1]
$p resume_row r1
wait_terminal $p r1 2000
check resume-done done [$p state r1]
$p destroy

# -- the whole queue holds, then drains ---------------------------------------

set p [new_pool 2]
$p pause_queue
foreach r {r1 r2 r3} { $p enqueue $r render fake_worker {plan {{sleep 30}}} }
set ::tick 0; after 50 {set ::tick 1}; vwait ::tick
check queue-held 3 [llength [$p queued_rows]]
$p resume_queue
foreach r {r1 r2 r3} { wait_terminal $p $r 3000 }
check queue-drained 3 [llength [lmap r {r1 r2 r3} {expr {[$p state $r] eq "done" ? $r : [continue]}}]]
$p destroy

# -- a terminal row is requeued and runs again --------------------------------

set p [new_pool 1]
$p enqueue r1 render fake_worker {plan {{sleep 20}}}
wait_terminal $p r1 2000
check requeue-first done [$p state r1]
$p requeue r1
wait_terminal $p r1 2000
check requeue-again done [$p state r1]
$p destroy

# -- a message for an unknown row is refused, not obeyed ----------------------

set logged {}
set p [jobpool new 1 -init $WORKER -log [list apply {{acc msg} {
    lappend ::logged $msg
}} logged]]
$p on_phase ghost somephase
check stale-refused 1 [expr {[string match "*phase for unknown row ghost*" $logged]}]
$p destroy

puts "----"
if {$fails} { puts "FAILED ($fails)" } else { puts PASS }
exit $fails
