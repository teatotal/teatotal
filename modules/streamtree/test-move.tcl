#!/usr/bin/env wish9.0
# move reparents a node under any parent, the empty one included, and its
# rows follow at the next rebuild: now, outside a batch, or once at the end
# of the batch that holds it, however many moves the batch made. While the
# rebuild waits the moved node has no row, so the buffer never shows a node
# under a parent the store has taken it from, and the gate stays quiet.

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
proc keys {d ids} { return [lmap id $ids { $d node_field $id key }] }

# The base class with its rebuilds counted.
oo::class create Counted {
    superclass ::streamtree::StreamTree
    variable Rebuilds
    constructor {parent} { set Rebuilds 0; my setup $parent }
    method rebuild {} { incr Rebuilds; next }
    method rebuilds {} { return $Rebuilds }
}

pack [ttk::frame .f] -fill both -expand 1
set d [Counted new .f]
set T .f.body.t

set f1 [$d insert "" folder f1 {label one}]
$d expand $f1
set a [$d insert $f1 row a {label a}]
set b [$d insert $f1 row b {label b}]
set f2 [$d insert "" folder f2 {label two}]
$d expand $f2
set c [$d insert $f2 row c {label c}]
update

# --- The empty parent makes a root, drawn after the roots before it.
$d move $a ""
check "a node moved to the empty parent is a root" "" [$d node_field $a parent]
check "last among the roots" {f1 f2 a} [keys $d [$d roots]]
check "gone from its old parent" {b} [keys $d [$d node_field $f1 children]]
check "drawn below the root before it" 1 [expr {[line_of $d $a] > [line_of $d $c]}]
check "one rebuild outside a batch" 1 [$d rebuilds]
check "invariant clean" 0 [tripped]

# --- Back under a folder: last among its new siblings, drawn in its body.
$d move $a $f2
check "reparented last among the new siblings" {c a} [keys $d [$d node_field $f2 children]]
check "no longer a root" {f1 f2} [keys $d [$d roots]]
check "drawn inside the new parent's region" 1 [expr {
    [$T compare [$d node_field $a start] > [$d node_field $f2 start]]
    && [$T compare [$d node_field $a end] <= [$d node_field $f2 end]]}]
check "one rebuild per move outside a batch" 2 [$d rebuilds]

# --- Inside a batch every move waits for the batch's end and pays one
#     rebuild between them. Meanwhile the moved node has no row, so an insert
#     in the same batch audits a buffer that agrees with the store.
set n [$d rebuilds]
$d batch {
    $d move $b $f2
    check "inside the batch the move has not rebuilt" $n [$d rebuilds]
    check "and the moved node has left the view" 0 [$d node_field $b rendered]
    $d move $c $f1
    set late [$d insert $f1 row late {label late}]
    check "an insert after the moves is invariant clean" 0 [tripped]
}
check "the batch's end paid one rebuild for two moves" [expr {$n + 1}] [$d rebuilds]
check "both nodes drawn under their new parents" {1 1} \
    [list [$d node_field $b rendered] [$d node_field $c rendered]]
check "the store has them where the moves put them" {{c late} {a b}} \
    [list [keys $d [$d node_field $f1 children]] [keys $d [$d node_field $f2 children]]]
check "and the buffer follows the store" 1 [expr {
    [line_of $d $f1] < [line_of $d $c] && [line_of $d $c] < [line_of $d $late]
    && [line_of $d $late] < [line_of $d $f2] && [line_of $d $f2] < [line_of $d $a]
    && [line_of $d $a] < [line_of $d $b]}]
check "batched moves, invariant clean" 0 [tripped]

# --- A batch inside a batch defers to the outermost end.
set n [$d rebuilds]
$d batch {
    $d batch { $d move $late $f2 }
    check "the inner batch's end does not rebuild" $n [$d rebuilds]
}
check "the outer batch's end does" [expr {$n + 1}] [$d rebuilds]
check "and the node is drawn under its new parent" 1 [$d node_field $late rendered]

# --- A rebuild the batch's script runs itself settles the debt.
set n [$d rebuilds]
$d batch {
    $d move $late $f1
    $d rebuild
}
check "an explicit rebuild inside the batch leaves nothing for its end" [expr {$n + 1}] [$d rebuilds]

# --- A batch that fails still rebuilds: the store moved before the error.
set n [$d rebuilds]
set code [catch {$d batch { $d move $a $f1; error boom }} err]
check "the error reaches the caller" {1 boom} [list $code $err]
check "the rebuild ran all the same" [expr {$n + 1}] [$d rebuilds]
check "and the view follows the store" 1 [$d node_field $a rendered]
check "with the node under its new parent" 1 [expr {$a in [$d node_field $f1 children]}]

# --- A node with no row (its parent is shut) moves without touching the
#     buffer, and a batch with no move rebuilds nothing.
$d collapse $f2
set n [$d rebuilds]
$d move $b $f1
check "a shut folder's child moves out and draws under its open parent" 1 [$d node_field $b rendered]
$d batch { $d insert $f1 row plain {label plain} }
check "a batch with no move rebuilds nothing" [expr {$n + 1}] [$d rebuilds]
check "every move, invariant clean" 0 [tripped]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
