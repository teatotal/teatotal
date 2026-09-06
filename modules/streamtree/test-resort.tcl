#!/usr/bin/env wish9.0
# The debounced resort after a streamed arrival. Every arrival schedules one
# rebuild, however many arrive before the delay runs out, unless the
# arrival_in_order hook says the active sort is the order they arrive in;
# the base class's own answer is no for every sort, and a header click
# cancels a resort still pending.

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file dirname [file normalize [info script]]]]]
foreach md [glob -directory [file join $ROOT modules] -type d *] { ::tcl::tm::path add $md }
package require streamtree
set ::env(STREAMTREE_AUDIT) 1

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name\n  expected: $expected\n  actual:   $actual"
        incr ::fails
    } else { puts "ok:   $name" }
}
proc tripped {} { return [expr {[info exists ::STREAMTREE_AUDIT_TRIPPED] ? 1 : 0}] }
# Let the resort's delay run out, and a little over.
proc settle {} { after 60 {set ::settled 1}; vwait ::settled }

# Rebuilds counted; one sortable column whose ascending order is the order
# rows arrive in, since each row's n is larger than the last.
oo::class create Counted {
    superclass ::streamtree::StreamTree
    variable Rebuilds
    constructor {parent} {
        set Rebuilds 0
        my configure -resortdelay 20
        my setup $parent
    }
    method rebuild {} { incr Rebuilds; next }
    method rebuilds {} { return $Rebuilds }
    method column_spec {} { return {{n N {9999} right 1}} }
    method cell_values {node} { return [list [list n [my node_pget $node n]]] }
}
oo::class create Ordered {
    superclass Counted
    method arrival_in_order {key dir} { return [expr {$key eq "n" && $dir eq "asc"}] }
}

pack [ttk::frame .f] -fill both -expand 1
set d [Ordered new .f]
set n 0
proc arrive {} {
    $::d insert "" row r[incr ::n] [dict create n $::n]
    $::d schedule_resort
}

# --- Under the first sortable column's default direction, descending,
#     arrivals are out of order: a burst of them pays one rebuild, after the
#     delay.
arrive; arrive; arrive
check "no rebuild before the delay runs out" 0 [$d rebuilds]
settle
check "a burst of arrivals pays one rebuild once they pause" 1 [$d rebuilds]

# --- Under the sort the hook vouches for, an arrival schedules nothing.
$d set_sort n
check "flipping to ascending is a rebuild of its own" 2 [$d rebuilds]
arrive; arrive
settle
check "arrivals in the order the sort keeps schedule no resort" 2 [$d rebuilds]
check "and each lands last among its siblings" {r1 r2 r3 r4 r5} [lmap id [$d roots] { $d node_field $id key }]

# --- A resort still pending is dropped by cancel_resort, and by the header
#     click that rebuilds anyway.
$d set_sort n
check "back to descending" 3 [$d rebuilds]
arrive
$d cancel_resort
settle
check "cancel_resort drops the pending resort" 3 [$d rebuilds]
arrive
$d set_sort n
settle
check "a header click cancels the resort pending behind it" 4 [$d rebuilds]

# --- The base class vouches for no sort: a plain tree resorts after every
#     burst, whatever its sort.
pack [ttk::frame .g] -fill both -expand 1
set plain [Counted new .g]
$plain insert "" row a [dict create n 1]
$plain schedule_resort
settle
check "the default hook schedules the resort under the default sort" 1 [$plain rebuilds]
$plain set_sort n
$plain insert "" row b [dict create n 2]
$plain schedule_resort
settle
check "and under the flipped one" 3 [$plain rebuilds]
check "invariant clean" 0 [tripped]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
