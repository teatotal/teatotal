#!/usr/bin/env tclsh9.0
# A standalone demo of jobpool: a batch of jobs run through a two-slot
# pool, their every state change printed as it happens, one job cancelled
# while it is already running, and one kind of work held to a single
# worker while the rest fan out. It loads only the jobpool module - no Tk.
#
# Run it:   tclsh9.0 demos/jobpool-demo.tcl

package require Tcl 9
set HERE [file dirname [file normalize [info script]]]
foreach md [glob -directory [file dirname $HERE] -type d *] { ::tcl::tm::path add $md }
package require jobpool

# Two kinds of work, one proc each. Each sleeps in short beats and calls
# checkpoint between them, so a cancel lands within a beat instead of at
# the end; the verb reads the sentinel and carries the report home. The
# pool seeds the verbs; a body picks them up with one namespace path line.
# heavy and light share one body through run_beats.
set WORKER {
    namespace path ::jobpool::worker
    proc run_beats {job opts} {
        for {set i 0} {$i < [dict get $opts beats]} {incr i} {
            checkpoint $job                 ;# a cancel or pause lands here
            after 200                       ;# the blocking beat a thread is for
        }
        done $job "[dict get $opts beats] beats"
    }
    proc heavy {job opts} { run_beats $job $opts }
    proc light {job opts} { run_beats $job $opts }
}

set pool [jobpool new 2 -init $WORKER]

set left 0
$pool subscribe job-state {apply {{job st} {
    puts [format "  %-10s %s" $job $st]
    if {$st in {done failed cancelled}} { incr ::left -1 }
}}}

puts "Two slots. One kind, 'heavy', is capped to a single worker; 'light'"
puts "fans out. Job light-2 is cancelled while it runs.\n"

$pool set_kind_cap heavy 1
foreach {job kind beats} {
    light-1 light 6
    light-2 light 30
    light-3 light 4
    heavy-1 heavy 5
    heavy-2 heavy 5
} {
    incr left
    $pool enqueue $job $kind [dict create beats $beats]
}

# Let light-2 get going, then cancel it mid-run.
after 500 { $pool cancel light-2 }

while {$left > 0} { vwait ::left }
puts "\nAll jobs terminal. Cancelled light-2 stopped mid-run, not at its end."
$pool destroy
