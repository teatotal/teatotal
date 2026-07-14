#!/usr/bin/env tclsh9.0
# A standalone demo of jobpool: a batch of jobs run through a two-slot
# pool, their every state change printed as it happens, one job cancelled
# while it is already running, and one kind of work held to a single
# worker while the rest fan out. It loads only the jobpool module - no Tk.
#
# Run it:   tclsh9.0 demos/jobpool-demo.tcl

package require Tcl 9
set HERE [file dirname [file normalize [info script]]]
::tcl::tm::path add [file dirname $HERE]
package require jobpool

# The worker: sleep in short beats, checking its cancel sentinel between
# them, so a cancel lands within a beat instead of at the end.
set WORKER {
    proc work {row opts} {
        for {set i 0} {$i < [dict get $opts beats]} {incr i} {
            if {[tsv::exists $::jobpool_tsv $row.cancel]} {
                thread::send -async $::main_tid \
                    [list $::pool on_cancelled $row]
                return
            }
            after 200
        }
        thread::send -async $::main_tid [list $::pool on_done $row]
    }
}

set pool [jobpool new 2 -init $WORKER]

set left 0
$pool subscribe row-state {apply {{row st} {
    puts [format "  %-10s %s" $row $st]
    if {$st in {done failed cancelled}} { incr ::left -1 }
}}}

puts "Two slots. One kind, 'scan', is capped to a single worker; 'build'"
puts "fans out. Job build-2 is cancelled while it runs.\n"

$pool set_worker_cap scan 1
foreach {row kind beats} {
    build-1 build 6
    build-2 build 30
    build-3 build 4
    scan-1  scan  5
    scan-2  scan  5
} {
    incr left
    $pool enqueue $row $kind work [dict create beats $beats]
}

# Let build-2 get going, then cancel it mid-run.
after 500 { $pool cancel build-2 }

while {$left > 0} { vwait ::left }
puts "\nAll jobs terminal. Cancelled build-2 stopped mid-run, not at its end."
$pool destroy
