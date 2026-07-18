#!/usr/bin/env tclsh9.0
# Tests for the deadman module: that a watched child's death is reported
# honestly (cause, exit code, signal), that each detector (stall, wall, the
# caller's poll) kills the tree and names itself, that the escalation ladder
# finishes a TERM-ignoring child, and that a kill scoped to the child's
# process group touches nothing else the user owns. The stub children are
# shell one-liners invented for the tests; the module knows nothing of any
# program that uses it.
package require Tcl 9
set ROOT [file dirname [file dirname [file dirname [file normalize [info script]]]]]
foreach md [glob -directory [file join $ROOT modules] -type d *] { ::tcl::tm::path add $md }
package require deadman

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
# Run the event loop until timers this short have fired.
proc drain {{ms 50}} {
    set ::_drained 0
    after $ms {set ::_drained 1}
    vwait ::_drained
}
set bgerrors 0
proc bgerror {msg} { incr ::bgerrors; puts stderr "bgerror: $msg" }

# Group kills need setsid (or gsetsid); without it the group-shaped
# assertions are skipped and the degraded lead-only mode is exercised.
set groupable [expr {[auto_execok setsid] ne "" || [auto_execok gsetsid] ne ""}]

# -- a clean exit reports its cause, code, and collected stdout ---------------

set r [deadman::run {sh -c {echo hi; exit 0}}]
check clean-cause  exit   [dict get $r cause]
check clean-exit   0      [dict get $r exit]
check clean-stdout "hi\n" [dict get $r stdout]

# -- a nonzero exit code survives the reap ------------------------------------

set r [deadman::run {sh -c {exit 7}}]
check code-cause exit [dict get $r cause]
check code-exit  7    [dict get $r exit]

# -- -out tees to a file as lines arrive; -line sees each one ------------------

set lines 0
proc countline {l} { incr ::lines }
close [file tempfile tee]
set r [deadman::run {sh -c {echo one; echo two}} -out $tee -line countline]
set fd [open $tee r]; set teed [read $fd]; close $fd
file delete $tee
check tee-content "one\ntwo\n" $teed
check line-count  2 $lines
check out-claims-stdout 0 [dict exists $r stdout]

# -- a child gone quiet dies of stall, promptly --------------------------------

set t0 [clock milliseconds]
set r [deadman::run {sh -c {echo a; sleep 30}} -stall 250 -grace 300]
set dt [expr {[clock milliseconds] - $t0}]
check stall-cause  stall [dict get $r cause]
check stall-prompt 1 [expr {$dt < 5000}]
if {$groupable} {
    check stall-signal SIGTERM [dict get $r signal]
}

# -- a chatty child still meets the wall clock ---------------------------------

set t0 [clock milliseconds]
set r [deadman::run {sh -c {while :; do echo tick; sleep 0.05; done}} \
    -wall 300 -grace 300]
set dt [expr {[clock milliseconds] - $t0}]
check wall-cause  wall [dict get $r cause]
check wall-prompt 1 [expr {$dt < 5000}]

# -- a TERM-trapping child dies at the KILL escalation -------------------------

if {$groupable} {
    set t0 [clock milliseconds]
    set r [deadman::run {sh -c {trap "" TERM; echo x; sleep 30}} \
        -stall 250 -grace 250]
    set dt [expr {[clock milliseconds] - $t0}]
    check trap-cause     stall   [dict get $r cause]
    check trap-escalated SIGKILL [dict get $r signal]
    check trap-prompt    1 [expr {$dt < 5000}]
} else {
    puts "skip: TERM-trap escalation (no setsid on PATH)"
}

# -- the poll callback outranks the stall on a shared tick, naming its cause ---

set polls 0
proc pollcb {h} {
    incr ::polls
    if {$::polls >= 2} { deadman::kill $h quota }
}
set r [deadman::run {sh -c {sleep 30}} -stall 150 -poll {100 pollcb} \
    -grace 300]
check poll-cause  quota [dict get $r cause]
check poll-called 2 $polls

# -- an undecodable byte on stdout neither wedges the drain nor fakes a stall --

set t0 [clock milliseconds]
set r [deadman::run {sh -c {printf 'ok\n\377bad\n'; exit 0}} \
    -stall 2000 -grace 300]
set dt [expr {[clock milliseconds] - $t0}]
check badbyte-cause  exit [dict get $r cause]
check badbyte-exit   0    [dict get $r exit]
check badbyte-prompt 1 [expr {$dt < 1500}]
check badbyte-lines  1 [string match "ok\n*bad\n" [dict get $r stdout]]

# -- -err stdout merges the child's stderr into the watched stream -------------

set r [deadman::run {sh -c {echo out; echo err >&2}} -err stdout]
check err-merged 1 [expr {[string match "*out*" [dict get $r stdout]] \
    && [string match "*err*" [dict get $r stdout]]}]

# -- stdin is fed whole, as UTF-8, and comes back through stdout ---------------

set r [deadman::run {cat} -stdin "héllo 中文\n"]
check stdin-roundtrip "héllo 中文\n" [dict get $r stdout]

# -- -done makes the run async; overlapping runs keep their results apart ------

array set got {}
proc done1 {res} { set ::got(1) $res }
proc done2 {res} { set ::got(2) $res }
deadman::run {sh -c {sleep 0.3; echo slow}} -done done1
deadman::run {sh -c {echo fast}} -done done2
vwait ::got(1)
check async-fast "fast\n" [dict get $got(2) stdout]
check async-slow "slow\n" [dict get $got(1) stdout]

# -- cancel kills without delivering anything ----------------------------------

set cancelled 0
proc nevercb {res} { incr ::cancelled }
set h [deadman::run {sh -c {sleep 30}} -done nevercb]
deadman::cancel $h
drain 400
check cancel-silent 0 $cancelled

# -- cancel from inside a -line callback, mid-drain, leaves nothing ------------

set line_cancelled 0
proc linecancel {line} {
    deadman::cancel $::lc_h
    incr ::line_cancelled
}
proc lc_never {res} { set ::lc_done 1 }
set lc_h [deadman::run {sh -c {echo first; echo second; sleep 30}} \
    -line linecancel -done lc_never]
drain 500
check line-cancel-once 1 $line_cancelled
check line-cancel-silent 0 [info exists ::lc_done]

# -- a kill landing on an already-reaped handle is a no-op ----------------------

set lk_res ""
proc lk_done {res} { set ::lk_res $res }
set lk_h [deadman::run {sh -c {echo done}} -done lk_done]
if {$lk_res eq ""} { vwait ::lk_res }
deadman::kill $lk_h stale
check late-kill-noop exit [dict get $lk_res cause]

# -- a bystander outside the group survives a group kill ------------------------
#    The regression that matters most: kill(1) reads an unescorted -<pid> as
#    -1, a broadcast to every process the caller owns. A module that loses
#    the -- escort kills this canary (and the test run with it).

set canary [exec sh -c {sleep 60 >/dev/null 2>&1 & echo $!}]
set r [deadman::run {sh -c {echo c; sleep 30}} -stall 200 -grace 200]
set alive [expr {![catch {exec kill -0 $canary}]}]
catch {exec kill -9 $canary}
check canary-survives-group-kill 1 $alive

# -- the aftermath is quiet: no timers left, no background errors ---------------

drain 600
check timers-clean 0 [llength [after info]]
check bgerrors-clean 0 $bgerrors

puts "----"
if {$fails} { puts "FAILED ($fails)" } else { puts PASS }
exit $fails
