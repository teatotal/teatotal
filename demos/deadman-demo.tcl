#!/usr/bin/env tclsh9.0
# A standalone demo of deadman: three fates for a child process. A clean run
# returns its output and exit code; a child gone silent is killed by the
# stall clock; a child that traps TERM is walked up the escalation ladder to
# KILL. Each verdict is the same dict: cause, exit, signal, stdout. It loads
# only the deadman module - no Tk.
#
# Run it:   tclsh9.0 demos/deadman-demo.tcl

package require Tcl 9
set HERE [file dirname [file normalize [info script]]]
::tcl::tm::path add [file dirname $HERE]
package require deadman

proc verdict {title res} {
    puts "  cause  [dict get $res cause]"
    puts "  exit   [dict get $res exit]"
    puts "  signal [dict get $res signal]"
    if {[dict exists $res stdout]} {
        puts "  stdout [string trim [dict get $res stdout]]"
    }
    puts ""
}

puts "1. A clean child: prints, exits 0."
verdict clean [deadman::run {sh -c {echo "work done"; exit 0}}]

puts "2. A child gone silent: one line, then nothing. The stall clock"
puts "   (500 ms here) kills the whole process group."
verdict stall [deadman::run {sh -c {echo "starting..."; sleep 60}} \
    -stall 500 -grace 500]

puts "3. A child that traps TERM: the grace expires and KILL finishes it."
verdict trap [deadman::run {sh -c {trap "" TERM; echo "can't stop me"; sleep 60}} \
    -stall 500 -grace 500]

puts "Sixty-second sleeps, three verdicts, and you waited about two seconds."
