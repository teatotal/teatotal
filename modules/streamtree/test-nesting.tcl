#!/usr/bin/env wish9.0
# Depth is not a number the base class knows. A node four levels down is a row
# like any other: the cursor walks to it, the audit gate sees its region inside
# its parent's, render_skip keeps it out on every path that could draw it, and
# a sibling set mixing kinds lines up by kind_rank before each kind sorts.

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

# A host of folders and files, folders nesting in folders. render_skip keeps
# out the keys in Skip and any folder with nothing under it, the skip a host
# derives from content and so cannot answer at insert; Kinds counts the most
# kinds any one sort_siblings call was handed, which the base class promises
# is one.
oo::class create Nested {
    superclass ::streamtree::StreamTree
    variable Skip Kinds
    constructor {parent} {
        set Skip [list]
        set Kinds 0
        my setup $parent
    }
    method skip {keys} { set Skip $keys }
    method kinds_seen {} { return $Kinds }
    method render_skip {id} {
        if {[my node_field $id key] in $Skip} { return 1 }
        return [expr {[my node_field $id kind] eq "folder" && ![llength [my node_field $id children]]}]
    }
    method kind_rank {kind} { return [expr {$kind eq "folder" ? 0 : 1}] }
    method sort_siblings {ids} {
        set n [llength [lsort -unique [lmap id $ids { my node_field $id kind }]]]
        if {$n > $Kinds} { set Kinds $n }
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

# --- reveal opens the way to a node shut three folders deep; expand_subtree
#     opens everything under a node in one sweep.
foreach id [list $l3 $l2 $l1] { $d collapse $id }
check "shut at every level, the leaf is off the roster" [list $l1] [$d all_rendered_nodes]
$d reveal $l4
check "reveal opens every ancestor" {1 1 1} [lmap a [$d ancestors $l4] { $d node_field $a expanded }]
check "and draws the row" 1 [$d node_field $l4 rendered]
$d cursor_set $l4
check "so the cursor may take it" $l4 [$d cursor]
foreach id [list $l3 $l2 $l1] { $d collapse $id }
$d expand_subtree $l1
check "expand_subtree opens every level under the node" [list $l1 $l2 $l3 $l4] [$d all_rendered_nodes]
check "reveal and expand_subtree, invariant clean" 0 [tripped]

# --- A skipped node stays out on every path that draws a node with its
#     content in place; insert, where the content has yet to arrive, draws on
#     the node's place alone.
$d skip {kept}
set kept [$d insert $l2 file kept [dict create label "kept out"]]
check "insert draws a node before its skip can be judged" 1 [$d node_field $kept rendered]
$d collapse $l2
$d expand $l2
check "expand asks the skip and leaves it out" 0 [$d node_field $kept rendered]
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
$d rebuild
check "a skipped root leaves the roster at the next rebuild" 0 [expr {$top in [$d all_rendered_nodes]}]
$d cursor_set $top
check "and refused the cursor" $l4 [$d cursor]
$d hide $l1
$d rebuild
check "a hidden root stays hidden through a rebuild" 0 [$d node_field $l1 rendered]
$d unhide $l1
check "skips and hides, invariant clean" 0 [tripped]

# --- A skip that content decides cannot be answered at insert: a folder is
#     born empty, so a skip reading "nothing under it" says no. insert draws
#     the folder on its place alone; the next rebuild asks the skip and drops
#     it; and expand is the door back once a child has landed, no rebuild
#     needed.
set late [$d insert "" folder late [dict create label "born empty"]]
check "insert draws a folder its skip cannot yet judge" 1 [$d node_field $late rendered]
$d rebuild
check "the next rebuild asks, and the empty folder goes" 0 [$d node_field $late rendered]
set kid [$d insert $late file kid [dict create label "first child"]]
check "a child born under an undrawn folder waits" 0 [$d node_field $kid rendered]
$d expand $late
check "expand draws the folder, now with content, and its child" {1 1} \
    [list [$d node_field $late rendered] [$d node_field $kid rendered]]
check "it came back at the tail, last among the roots as in the view" $late [lindex [$d roots] end]
check "a late folder, invariant clean" 0 [tripped]

# --- A folder holding files and sub-folders, inserted interleaved: the
#     sub-folders come first by kind_rank, each run in sort_siblings order,
#     and sort_siblings never sees two kinds at once.
set mix [$d insert "" folder mix [dict create label mixed]]
$d expand $mix
foreach {kind key label} {file fz zeta folder fb beta file fa alpha folder fd delta} {
    set n($key) [$d insert $mix $kind $key [dict create label $label]]
}
foreach f {fb fd} { $d insert $n($f) file $f.x [dict create label x] }
$d rebuild
check "kinds line up by kind_rank, each run sorted" {fb fd fa fz} \
    [lmap id [$d node_field $mix children] { $d node_field $id key }]
check "sort_siblings was handed one kind at a time" 1 [$d kinds_seen]
check "the mixed set drew in that order" {fb fd fa fz} \
    [lmap id [lrange [$d all_rendered_nodes] end-3 end] { $d node_field $id key }]

# With the default kind_rank every kind ranks alike, and the kinds keep the
# order they first appear in.
pack [ttk::frame .g] -fill both -expand 1
set plain [::streamtree::StreamTree new]
$plain setup .g
set r [$plain insert "" folder r [dict create label r]]
$plain expand $r
foreach {kind key} {file a folder b file c folder d} {
    $plain insert $r $kind $key [dict create label $key]
}
$plain rebuild
check "the default rank keeps kinds in first-seen order" {a c b d} \
    [lmap id [$plain node_field $r children] { $plain node_field $id key }]

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
