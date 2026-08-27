#!/usr/bin/env wish9.0
# The cursor: the row the keyboard walks from.
#
# It steps over the rows actually drawn, so a shut folder's children are not on
# the walk until Right opens it, and every move reaches the host through
# -cursorcb, which is the only way a host learns of one - the class paints
# nothing for the cursor and reads no meaning into it.

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

pack [ttk::frame .f] -fill both -expand 1
set d [::streamtree::StreamTree new]
set ::moves [list]
$d configure -cursorcb [list apply {{id prev} { lappend ::moves [list $id $prev] }}]
$d setup .f
set T .f.body.t

# Two folders, three rows each. The first is open, the second shut.
set open_f [$d insert "" folder open [dict create label "open folder"]]
set shut_f [$d insert "" folder shut [dict create label "shut folder"]]
set rows [list]
foreach f [list $open_f $shut_f] {
    for {set i 0} {$i < 3} {incr i} {
        lappend rows [$d insert $f item "[$d node_field $f key]$i" \
            [dict create label "row $i"]]
    }
}
$d expand $open_f
update

check "no cursor before a key" "" [$d cursor]

# --- Down from nothing takes the first drawn row, then steps.
$d cursor_move next
check "the first move lands on the first row" [lindex [$d all_rendered_nodes] 0] [$d cursor]
$d cursor_move next
check "the second move steps one row on" [lindex [$d all_rendered_nodes] 1] [$d cursor]
$d cursor_move prev
check "prev steps back" [lindex [$d all_rendered_nodes] 0] [$d cursor]
$d cursor_move prev
check "prev stops at the top" [lindex [$d all_rendered_nodes] 0] [$d cursor]

# --- The host heard every move that happened, and nothing else.
check "the host heard three moves" 3 [llength $::moves]
check "each move carried the row it left" [lindex [$d all_rendered_nodes] 1] \
    [lindex $::moves 2 1]

# --- A shut folder's rows are not on the walk; End reaches its heading.
$d cursor_move last
check "last is the shut folder's heading, not a row inside it" $shut_f [$d cursor]
check "a shut folder's children are not drawn" 0 \
    [expr {[lindex $rows 3] in [$d all_rendered_nodes]}]

# --- Right opens it and its rows join the walk; Left shuts it again.
$d cursor_open 1
update
check "Right drew the shut folder's children" 1 \
    [expr {[lindex $rows 3] in [$d all_rendered_nodes]}]
$d cursor_move next
check "the walk now steps into the folder" [lindex $rows 3] [$d cursor]
$d cursor_set $shut_f
$d cursor_open 0
update
check "Left shut it again" 0 \
    [expr {[lindex $rows 3] in [$d all_rendered_nodes]}]

# --- first goes to the top row.
$d cursor_move first
check "first is the top row" [lindex [$d all_rendered_nodes] 0] [$d cursor]

# --- A node that is not drawn cannot hold the cursor.
$d cursor_set [lindex $rows 3]
check "an undrawn node is refused the cursor" [lindex [$d all_rendered_nodes] 0] [$d cursor]

# --- A move brings its row into view. Fill the open folder until it scrolls.
for {set i 0} {$i < 200} {incr i} {
    $d insert $open_f item "fill$i" [dict create label "filler $i"]
}
update
$T yview moveto 0
update
$d cursor_move last
update
check "the last row is in view after the move" 1 \
    [expr {[lindex [$T yview] 1] > 0.9}]

# --- A node leaving the store takes the cursor with it, so no key can act on a
#     row that is gone.
set gone [$d cursor]
$d delete $gone
check "delete clears the cursor it held" "" [$d cursor]
check "a key on a cleared cursor is inert" 0 [catch {$d cursor_open 1}]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
