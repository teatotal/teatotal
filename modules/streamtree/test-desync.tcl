#!/usr/bin/env wish9.0
# The three desyncs 0.5.2 settled, each guarded here so questlog's suite is not
# the only thing that catches a regression.
#
#   unhide       drew a shown row at the folder's append point (the tail) but
#                left the node where it sat in the store. Under a store-order
#                sort the next rebuild would jump it back. unhide now
#                reattach_last, so the store follows the view, as expand does
#                for a late-drawn node.
#   the gate     judged siblings in STORE order, so a host that draws a sibling
#                set in a sorted order over an arrival-order store (seated only
#                at the next rebuild) tripped it, though every region was
#                well-formed, disjoint and nested. The gate now judges
#                disjointness in BUFFER order; a store order out of step with
#                the buffer is the rebuild's to settle, not a mark desync. The
#                disjointness check itself stays: a genuine overlap still trips.
#   render_row   dropped its insert silently when a host reached it with the
#                widget -state disabled (a flush that skipped its batch), drawing
#                a zero-length row whose right-gravity start split from its
#                left-gravity end on the next insert there - end before start.
#                render_row now draws editable and restores, as the primitives do.

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
proc line_of {d id} { return [lindex [split [$::T index [$d node_field $id start]] .] 0] }
proc labels {d ids} { return [lmap id $ids { $d node_pget $id label }] }

pack [ttk::frame .f] -fill both -expand 1
set d [::streamtree::StreamTree new]
$d setup .f
set T .f.body.t

# --- unhide reattaches the shown node last in the store -----------------------
# Three rows under one folder; hide the middle one, then bring it back.
set f [$d insert "" folder f {label F}]
$d expand $f
set a [$d insert $f row a {label a}]
set b [$d insert $f row b {label b}]
set c [$d insert $f row c {label c}]
check "three rows drawn in store order" {a b c} [labels $d [$d node_field $f children]]
$d hide $b
$d unhide $b
check "unhide is invariant-clean" 0 [tripped]
check "the shown node is reattached last in the store" [list $a $c $b] [$d node_field $f children]
check "and the buffer order follows the store: a, c, b" 1 \
    [expr {[line_of $d $a] < [line_of $d $c] && [line_of $d $c] < [line_of $d $b]}]

# --- the gate judges siblings in buffer order, not store order ----------------
# Draw three rows, then reorder only the store (a sort the host will seat at the
# next rebuild). The buffer is unchanged; the regions stay well-formed, disjoint
# and nested, so the in-place heading rewrite must read no desync.
set g [$d insert "" folder g {label G}]
$d expand $g
set x [$d insert $g row x {label x}]
set y [$d insert $g row y {label y}]
set z [$d insert $g row z {label z}]
$d node_set $g children [list $z $x $y]
$d item $g
check "a store order out of step with the buffer is not a desync" 0 [tripped]
$d rebuild
check "and the rebuild seats the store's order in the buffer" {z x y} \
    [labels $d [$d node_field $g children]]
check "the rebuild is invariant-clean" 0 [tripped]

# --- render_row draws editable even when a host reaches it disabled -----------
# A host helper (a search flush past its batch bracket) reaches render_row with
# the widget disabled. The insert must land: a zero-length row would invert on
# the next sibling insert.
set h [$d insert "" folder h {label H}]
$d expand $h
set s1 [$d node_new row $h s1 {label one}]
$d node_set $h children [list {*}[$d node_field $h children] $s1]
$T configure -state disabled
$d render_row $s1
$T configure -state normal
check "a row rendered against a disabled widget is non-empty" 1 \
    [expr {[$T compare [$d node_field $s1 end] > [$d node_field $s1 start]]}]
set s2 [$d insert $h row s2 {label two}]
check "a sibling appended after the disabled render is invariant-clean" 0 [tripped]
check "the disabled-rendered row is still well-formed" 1 \
    [expr {[$T compare [$d node_field $s1 end] >= [$d node_field $s1 start]]}]

# --- the disjointness check still bites --------------------------------------
# The order relaxation kept the overlap check: push one region over its sibling
# and the gate must still name it. Its stderr report is swallowed so the runner
# does not read a deliberate trip as a real one, and the latch is lifted after.
namespace eval swallow {
    proc initialize {ch mode} { return {initialize finalize write flush} }
    proc finalize {ch} {}
    proc write {ch data} { return "" }
    proc flush {ch} { return "" }
    namespace export initialize finalize write flush
    namespace ensemble create
}
set xe [$d node_field $x end]
set was [$T index $xe]
$T mark set $xe [$T index [$d node_field $y end]]
chan push stderr swallow
$d check_invariant probe
chan pop stderr
check "a region overlapping its sibling still trips the gate" 1 [tripped]
$T mark set $xe $was
unset ::STREAMTREE_AUDIT_TRIPPED
$d check_invariant probe
check "and the gate is quiet once the regions are disjoint again" 0 [tripped]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
