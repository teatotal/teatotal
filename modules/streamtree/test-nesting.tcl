#!/usr/bin/env wish9.0
# Depth is not a number the base class knows. A node four levels down is a row
# like any other: the cursor walks to it, the audit gate sees its region inside
# its parent's, and render_skip keeps it out on every path that could draw it.

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
# The line a node's row starts on, to check the roster against the buffer.
proc line_of {d id} { return [lindex [split [$::T index [$d node_field $id start]] .] 0] }

# A host of folders and files, folders nesting in folders. Skip holds the keys
# render_skip keeps out of the view.
oo::class create Nested {
    superclass ::streamtree::StreamTree
    variable Skip
    constructor {parent} {
        set Skip [list]
        my setup $parent
    }
    method skip {keys} { set Skip $keys }
    method render_skip {id} { return [expr {[my node_field $id key] in $Skip}] }
    method sort_siblings {ids} {
        set keyed [lmap id $ids { list $id [my node_pget $id label] }]
        return [lmap e [lsort -dictionary -index 1 $keyed] { lindex $e 0 }]
    }
}

pack [ttk::frame .f] -fill both -expand 1
set d [Nested new .f]
set T .f.body.t

# --- Four levels, every folder open: the cursor reaches the bottom.
set l1 [$d insert "" folder l1 [dict create label "level one"]]
$d expand $l1
set l2 [$d insert $l1 folder l2 [dict create label "level two"]]
$d expand $l2
set l3 [$d insert $l2 folder l3 [dict create label "level three"]]
$d expand $l3
set l4 [$d insert $l3 file l4 [dict create label "level four"]]
update
check "four levels draw, invariant clean" 0 [tripped]
check "the roster runs root to leaf" [list $l1 $l2 $l3 $l4] [$d all_rendered_nodes]
check "in the buffer's own order" {1 2 3 4} [lmap id [$d all_rendered_nodes] { line_of $d $id }]
foreach _ {1 2 3 4} { $d cursor_move next }
check "four Downs reach depth four" $l4 [$d cursor]
$d cursor_set $l1
$d cursor_set $l4
check "cursor_set takes a node at depth four" $l4 [$d cursor]
check "ancestors climb nearest first" [list $l3 $l2 $l1] [$d ancestors $l4]
check "descendants run parents before children" [list $l2 $l3 $l4] [$d descendants $l1]

# --- The primitives at depth: a shut middle folder takes its subtree off the
#     roster, and reopening it draws the open subtree back, not one level.
$d collapse $l2
check "a shut middle folder takes its subtree off the roster" [list $l1 $l2] [$d all_rendered_nodes]
$d expand $l2
check "reopening it draws every open level under it" [list $l1 $l2 $l3 $l4] [$d all_rendered_nodes]
$d hide $l3
$d unhide $l3
check "hide and unhide at depth three bring the leaf back too" 1 [$d node_field $l4 rendered]
$d node_pset $l3 label "level three, renamed"
$d item $l3
set m [$d append_open $l4]
$d emit $m "loose content under the leaf\n" {}
$d append_close $l4 $m
check "every ancestor end rides the loose content forward" \
    [lrepeat 4 [$T index [$d node_field $l4 end]]] \
    [lmap id [list $l1 $l2 $l3 $l4] { $T index [$d node_field $id end] }]
check "item, hide, unhide and the content door at depth, invariant clean" 0 [tripped]

# --- A skipped node stays out on every path that draws.
$d skip {kept}
set kept [$d insert $l2 file kept [dict create label "kept out"]]
check "insert does not draw a skipped node" 0 [$d node_field $kept rendered]
$d collapse $l2
$d expand $l2
check "expand does not draw it" 0 [$d node_field $kept rendered]
$d hide $kept
$d unhide $kept
check "unhide does not draw it" 0 [$d node_field $kept rendered]
$d rebuild
check "rebuild does not draw it" 0 [$d node_field $kept rendered]
$d skip {}
$d rebuild
check "the skip lifted, the next rebuild draws it" 1 [$d node_field $kept rendered]
$d skip {top}
set top [$d insert "" folder top [dict create label "skipped root"]]
check "a skipped root is off the roster" 0 [expr {$top in [$d all_rendered_nodes]}]
$d cursor_set $top
check "and refused the cursor" $l4 [$d cursor]
$d hide $l1
$d rebuild
check "a hidden root stays hidden through a rebuild" 0 [$d node_field $l1 rendered]
$d unhide $l1
check "skips and hides, invariant clean" 0 [tripped]

# --- The gate sees a nested desync. Level three's end mark pushed past its
#     parent's leaves every root region intact, so a roots-only audit would
#     pass it; the nested one names the escape. Its report goes to stderr,
#     swallowed here so the runner does not read a deliberate trip as a real
#     one, and the latch is lifted after.
namespace eval swallow {
    proc initialize {ch mode} { return {initialize finalize write flush} }
    proc finalize {ch} {}
    proc write {ch data} { return "" }
    proc flush {ch} { return "" }
    namespace export initialize finalize write flush
    namespace ensemble create
}
set l3_end [$d node_field $l3 end]
set was [$T index $l3_end]
$T mark set $l3_end end
chan push stderr swallow
$d check_invariant probe
chan pop stderr
check "the nested audit sees a child escaping its parent" 1 [tripped]
$T mark set $l3_end $was
unset ::STREAMTREE_AUDIT_TRIPPED
$d check_invariant probe
check "and is quiet once the mark is back" 0 [tripped]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
