#!/usr/bin/env tclsh9.0
# A standalone demo of jobloop: a batch of jobs run through a two-slot pool
# of coroutines - no threads, one interpreter, the event loop the script
# already has. Every state change prints as it happens, one job is cancelled
# while it is already mid-wait, one kind of work is held to a single slot
# while the rest fan out, and a paced kind launches no faster than its floor.
# It loads only the jobloop module - no Tk.
#
# Run it:   tclsh9.0 demos/jobloop-demo.tcl

package require Tcl 9
set HERE [file dirname [file normalize [info script]]]
::tcl::tm::path add [file dirname $HERE]
package require jobloop

# Two kinds of work, one body. Each beat waits the loop's way - an after
# that resumes the coroutine, then a yield - so the slot is never blocked
# and a cancel or pause lands at the checkpoint between beats, not at the
# end. heavy and light share run_beats.
namespace path ::jobloop::worker
proc run_beats {job opts} {
    set n [dict get $opts beats]
    for {set i 1} {$i <= $n} {incr i} {
        after 200 [info coroutine]      ;# resume me in 200 ms
        yield                           ;# park; the loop runs everyone else
        checkpoint $job                 ;# a cancel or pause lands here
    }
    done $job "$n beats"
}
proc heavy {job opts} { run_beats $job $opts }
proc light {job opts} { run_beats $job $opts }

set loop [jobloop new 2]

set left 0
$loop subscribe job-state {apply {{job st} {
    puts [format "  %-10s %s" $job $st]
    if {$st in {done failed cancelled}} { incr ::left -1 }
}}}
$loop subscribe kind-held {apply {{kind} {
    puts "  (kind '$kind' held back; its running jobs finish undisturbed)"
}}}

puts "Two slots, all coroutines on this one event loop - no threads. The"
puts "kind 'heavy' is capped to a single slot and paced to 500 ms between"
puts "launches; 'light' fans out. Job light-2 is cancelled mid-wait.\n"

$loop set_kind_cap heavy 1
$loop set_kind_pace heavy 500
foreach {job kind beats} {
    light-1 light 6
    light-2 light 30
    light-3 light 4
    heavy-1 heavy 5
    heavy-2 heavy 5
} {
    incr left
    $loop enqueue $job $kind [dict create beats $beats]
}

# Let light-2 get going, then cancel it while it is parked between beats.
after 500 { $loop cancel light-2 }

while {$left > 0} { vwait ::left }
puts "\nAll jobs terminal. Cancelled light-2 stopped at a checkpoint, mid-wait."
$loop destroy
