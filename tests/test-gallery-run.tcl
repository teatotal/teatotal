#!/usr/bin/env wish9.0
# Test for the gallery's demo runner: pressing Run launches the selected
# demo as a watched subprocess, its output streams in, and completion
# re-enables the button. The deadman demo is the subject because it is
# CLI-only and exercises the runner's kill ladder inside the child.
package require Tk

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

set argv {--demo deadman}
set argc 2
source [file join [file dirname [file dirname [file normalize [info script]]]] \
    demos gallery.tcl]

after 1500 { .bar.run invoke }
after 12000 {
    check run-completed-reenables 0 \
        [expr {"disabled" in [.bar.run state]}]
    puts "----"
    if {$::fails} { puts "FAILED ($::fails)" } else { puts PASS }
    exit $::fails
}
