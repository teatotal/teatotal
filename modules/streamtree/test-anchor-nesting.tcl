#!/usr/bin/env wish9.0
# The anchor bracket nests: a bracket opened inside an open one (a batch
# inside a batch, a primitive that batches inside a host's own anchor_save)
# is a no-op, so the outermost restore still finds the record it saved (the
# AnchorTop mark, which an unguarded inner restore unset) and a reader inside
# the list keeps their line through the whole run, rows landing above them
# between the inner close and the outer.

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
proc top_text {} { return [$::T get @0,0 "@0,0 lineend"] }
proc anchored {} { return [expr {"AnchorTop" in [$::T mark names]}] }

pack [ttk::frame .f] -fill both -expand 1
set d [::streamtree::StreamTree new]
$d setup .f
set T .f.body.t
set n 0
# A row above every other: the reader is below it, so it shifts what they
# see unless the anchor compensates.
proc above {} {
    global d n
    $d insert "" row "a[incr n]" [dict create label "above $n"] -pos [list before [lindex [$d roots] 0]]
}
$d batch { for {set i 0} {$i < 200} {incr i} { $d insert "" row r$i [dict create label "row $i"] } }
update
$T yview moveto 0.5
update
set line0 [top_text]

# --- A host's own bracket around a batch: the batch's restore leaves the
#     host's record alone, and a row landing after the batch is compensated
#     by the host's restore.
$d anchor_save
check "the outer bracket holds its record" 1 [anchored]
$d batch { above }
check "an inner batch's close leaves the outer's record standing" 1 [anchored]
above
$d anchor_restore
check "the outer close drops it" 0 [anchored]
update
check "a batch inside a host bracket leaves the reader's line to the outer restore" $line0 [top_text]

# --- A batch inside a batch, rows landing above the reader in both.
$d batch {
    above
    $d batch { above }
    check "a batch inside a batch leaves the outer's record standing" 1 [anchored]
    above
}
update
check "nested batches hold the reader's line" $line0 [top_text]

# --- A primitive that batches for itself (expand_subtree) inside a host
#     bracket, then more rows above.
set f [$d insert "" folder f [dict create label folder] -pos [list before [lindex [$d roots] 0]]]
$d insert $f row fx [dict create label fx]
$d anchor_save
$d expand_subtree $f
above
$d anchor_restore
update
check "a batching primitive inside a host bracket holds the line" $line0 [top_text]

# --- A reader at the top stays pinned there through the same nesting.
$T yview moveto 0
update
$d anchor_save
$d batch { above }
above
$d anchor_restore
update
check "a reader at the top stays at the top" 1 [expr {[lindex [$T yview] 0] <= 0.0001}]
check "invariant clean" 0 [expr {[info exists ::STREAMTREE_AUDIT_TRIPPED] ? 1 : 0}]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
