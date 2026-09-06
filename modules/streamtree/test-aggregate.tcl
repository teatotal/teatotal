#!/usr/bin/env wish9.0
# What a folder adds up to is a fold the base class walks and the host fills:
# aggregate_seed starts it, aggregate_add takes one node into it, and
# node_aggregate carries it over a node and everything under it. Nothing is
# cached, so the answer after a move, a delete, a hide or a rewritten payload
# is the tree as it stands; asked for shown nodes only, a hidden node leaves
# with its whole subtree, as hide takes it from the view.

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

# A host of folders and files: a file carries a cost, a folder carries none.
# The fold counts the files and sums their cost; a folder adds nothing of its
# own, so what it reads is what sits beneath it.
oo::class create Totals {
    superclass ::streamtree::StreamTree
    constructor {parent} { my setup $parent }
    method aggregate_seed {} { return [dict create count 0 cost 0.0] }
    method aggregate_add {acc id} {
        if {[my node_field $id kind] ne "file"} { return $acc }
        dict incr acc count
        dict set acc cost [expr {[dict get $acc cost] + [my node_pget $id cost 0]}]
        return $acc
    }
}
proc folder {d parent key} { return [$d insert $parent folder $key [dict create label $key]] }
proc file_ {d parent key cost} {
    return [$d insert $parent file $key [dict create label $key cost $cost]]
}

pack [ttk::frame .f] -fill both -expand 1
set d [Totals new .f]

# project holds two files and two sub-folders, one with a folder of its own
# under it; other is a second root a move can reach. Nothing is open yet.
set proj [folder $d "" project]
set a [file_ $d $proj a 1.0]
set b [file_ $d $proj b 2.0]
set lib [folder $d $proj lib]
set c [file_ $d $lib c 4.0]
set deep [folder $d $lib deep]
set e [file_ $d $deep e 8.0]
set docs [folder $d $proj docs]
set f [file_ $d $docs f 16.0]
set other [folder $d "" other]
set g [file_ $d $other g 32.0]

check "a root folds every file at any depth, open or not" {count 5 cost 31.0} [$d node_aggregate $proj]
check "a sub-folder folds its own subtree" {count 2 cost 12.0} [$d node_aggregate $lib]
check "a file folds to itself" {count 1 cost 8.0} [$d node_aggregate $e]
check "a folder with nothing under it folds to the seed" {count 0 cost 0.0} \
    [$d node_aggregate [folder $d $other empty]]

# --- Shown only: a hidden file leaves, and a hidden folder leaves with its
#     whole subtree; the all-nodes fold does not move.
$d expand_subtree $proj
$d hide $b
$d hide $lib
check "every node: the hides change nothing" {count 5 cost 31.0} [$d node_aggregate $proj]
check "shown only: the hidden file and the hidden folder's subtree are out" \
    {count 2 cost 17.0} [$d node_aggregate $proj 1]
check "the hidden folder itself, shown only, is the seed" {count 0 cost 0.0} [$d node_aggregate $lib 1]
$d unhide $lib
check "unhide brings the subtree back" {count 4 cost 29.0} [$d node_aggregate $proj 1]
$d unhide $b
$d collapse $proj
check "a shut folder still adds up" {count 5 cost 31.0} [$d node_aggregate $proj 1]

# --- After a move, a delete and a rewritten payload, nothing stale survives.
$d move $lib $other
check "after a move the source has lost the subtree" {count 3 cost 19.0} [$d node_aggregate $proj]
check "and the destination has gained it" {count 3 cost 44.0} [$d node_aggregate $other]
$d delete $deep
check "after a delete nothing of the subtree survives" {count 2 cost 36.0} [$d node_aggregate $other]
$d node_pset $g cost 64.0
check "a rewritten payload is in the next answer" {count 2 cost 68.0} [$d node_aggregate $other]
check "the fold mutates nothing, invariant clean" 0 [tripped]

# --- The default hooks count nodes, so the plain base class answers a
#     subtree's size, and shown only, the size less what is hidden.
pack [ttk::frame .g] -fill both -expand 1
set plain [::streamtree::StreamTree new]
$plain setup .g
set r [$plain insert "" folder r [dict create label r]]
set s [$plain insert $r folder s [dict create label s]]
$plain insert $s row x [dict create label x]
$plain insert $r row y [dict create label y]
check "the default fold counts the node and everything under it" 4 [$plain node_aggregate $r]
$plain hide $s
check "shown only, less the hidden subtree" 2 [$plain node_aggregate $r 1]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
