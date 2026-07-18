#!/usr/bin/env tclsh9.0
# A standalone demo of ocmdline: a command line whose parser and help render
# from one option table, so the help cannot promise a flag the parser refuses.
# The tool is `steep`, a tea timer: a positional tea name, then typed flags.
# It loads only the ocmdline module - no Tk.
#
# Run it:   tclsh9.0 demos/ocmdline-demo.tcl oolong --temp 90 --time 180
#           tclsh9.0 demos/ocmdline-demo.tcl --help
#
# Every line the help prints below comes from the declarations here; there is
# no second copy of the grammar to drift.

package require Tcl 9
set HERE [file dirname [file normalize [info script]]]
foreach md [glob -directory [file dirname $HERE] -type d *] { ::tcl::tm::path add $md }
package require ocmdline

set cl [ocmdline new steep 1.0]
$cl synopsis {<tea> [options]}
$cl preamble {{Steep a tea: say which leaf, then how.}}
$cl section brew {brewing:}
$cl option --temp -section brew -arg celsius \
    -check {expr {[string is integer -strict $value] ? "" : "--temp: not a number: '$value'"}} \
    -fold {set temp $value} \
    -help {{Water temperature in celsius.}}
$cl option --time -section brew -arg seconds \
    -check {expr {[string is integer -strict $value] ? "" : "--time: not a number: '$value'"}} \
    -fold {set secs $value} \
    -help {{Steeping time in seconds.}}
$cl option --note -section brew -arg text -repeat \
    -fold {lappend notes $value} \
    -help {{A tasting note to record; repeat for more.}}
$cl reject -help {help is spelled --help}

# The help and version requests are read before anything else runs, so the
# positional check below cannot swallow a plain `steep --help`.
switch [$cl asks $argv] {
    help    { $cl print; exit 0 }
    version { puts [$cl version_line]; exit 0 }
}

# The positional: the tea comes first, everything after it is the grammar's.
# A line that leads with a flag still goes through parse whole, so a mistyped
# option is refused in the table's words rather than mistaken for a tea.
set tea [lindex $argv 0]
set rest [lrange $argv 1 end]
if {[string match -* $tea]} { set tea ""; set rest $argv }
try {
    set r [$cl parse $rest]
} trap {OCMDLINE USAGE} {msg} {
    $cl abort $msg
}
if {$tea eq ""} { $cl abort "which tea? the leaf comes first" }

# Fold the ordered occurrences into settings: each option's -fold script runs
# here in the caller's scope, with `value` and `suffix` set, exactly as the
# declaration promised.
set temp 85
set secs 120
set notes [list]
foreach o [dict get $r occurrences] {
    set value  [dict get $o value]
    set suffix [dict get $o suffix]
    eval [$cl fold_of [dict get $o name]]
}

puts "steeping:  $tea"
puts "water:     ${temp}c"
puts "time:      ${secs}s"
if {[llength $notes]} { puts "notes:     [join $notes {; }]" }
