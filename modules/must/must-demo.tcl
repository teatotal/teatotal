#!/usr/bin/env tclsh9.0
# A standalone demo of must: the factor it pulls from a pattern, and the scan
# that factor saves. It loads only the must module - no Tk.
#
# Run it:   tclsh9.0 modules/must/must-demo.tcl

package require Tcl 9
set HERE [file dirname [file normalize [info script]]]
foreach md [glob -directory [file dirname $HERE] -type d *] { ::tcl::tm::path add $md }
package require must

puts "1. The factor of a pattern: the substring every match must contain."
puts "   No factor means nothing is provably required, so every line stays a"
puts "   candidate and the pattern gates nothing."
foreach pat {
    {[^A-Za-z]K9[^A-Za-z]}
    {colou?r}
    {(?i)error}
    {foo|bar}
    {[0-9]{4}}
} {
    lassign [must::factor $pat] f nocase
    if {$f eq ""} {
        set shown "(none)"
    } else {
        set shown "\"$f\"[expr {$nocase ? { (fold case)} : {}}]"
    }
    puts [format {   %-24s -> %s} $pat $shown]
}
puts ""

puts "2. The filter in a scan loop: the regex runs only where the factor is."
set pat {[^A-Za-z]K9[^A-Za-z]}
set keep [must::filter $pat]
set lines {
    "the K9 core dumped"
    "an ordinary line of prose"
    "another quiet line, nothing here"
    "K9 shows up again"
}
set tested 0
set hits 0
foreach line $lines {
    if {![{*}$keep $line]} continue
    incr tested
    if {[regexp -- $pat $line]} { incr hits; puts "   match: $line" }
}
puts "   [llength $lines] lines; the regex ran on $tested, and $hits matched."
puts "   The [expr {[llength $lines] - $tested}] lines without the factor were skipped untouched."
