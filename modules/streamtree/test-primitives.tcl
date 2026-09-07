#!/usr/bin/env wish9.0
# Drive the StreamTree structural primitives directly on a minimal subclass, with
# the audit gate on, asserting after each that the mark contract holds and that
# the buffer returns to its empty baseline (no leaked marks or tags) once every
# node is gone. This exercises the base class's mark ownership in isolation, before
# any host wiring rides on it.

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file dirname [file normalize [info script]]]]]
foreach md [glob -directory [file join $ROOT modules] -type d *] { ::tcl::tm::path add $md }
package require streamtree
set ::env(STREAMTREE_AUDIT) 1

# The test supplies its own look, the way any host does: two named fonts and a
# plain colours dict through `configure`. Nothing asserted below depends on a
# particular font or colour; the base class only needs real ones to measure with.
font create TestList {*}[font actual TkTextFont]
font create TestHead {*}[font actual TkTextFont] -weight bold

# A minimal concrete StreamTree: three node kinds nested folder>session>subagent,
# one metadata column, per-kind start gravity and style tags, and a trivial
# subject. The folder>session>subagent kinds are invented shapes for the test.
oo::class create Demo {
    superclass ::streamtree::StreamTree
    variable Top Text Nodes Roots NextId ColTabs ColRightX ColW ColGap \
        SubjectMax LabelMax LayoutW RelayoutPending SortKey SortDir \
        ResortTimer AtTop
    constructor {parent} {
        my configure -listfont TestList -headfont TestHead \
            -colours [dict create strip #e8eef2 muted #5a6b78 ink #102a43]
        set Top $parent
        my reset_nodes
        set NextId 0
        set SortKey date
        set SortDir desc
        set RelayoutPending 0
        set ResortTimer ""
        set LayoutW -1
        my build_body
        my compute_col_widths
        my build_header
        update idletasks
        my relayout
    }
    method column_spec {} { return {{n N {9999} right 0}} }
    method render_subject {node max} { return [dict create subject [my node_pget $node label] tags {} meta_run 0] }
    method cell_values {node} { return [list [list n [my node_pget $node n 0]]] }
    method cell_tag {node col} { return [list] }
    method sort_key {payload col} { return 0 }
    method apply_column_tabs {tabs} {}
    method relayout_content {} {}
    method start_gravity {kind} { return [expr {$kind eq "subagent" ? "left" : "right"}] }
    method row_tags {kind} {
        return [dict get {folder folderhead session sessionhead subagent childhead} $kind]
    }
}

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name\n  expected: $expected\n  actual:   $actual"
        incr ::fails
    } else { puts "ok:   $name" }
}
proc tripped {} { return [expr {[info exists ::STREAMTREE_AUDIT_TRIPPED] ? 1 : 0}] }
# Count the position marks the base class owns (named <node>_s / <node>_e), so a
# leak (a row removed but its marks left live) is visible as a non-zero residue.
proc live_marks {w} {
    set n 0
    foreach m [$w mark names] { if {[string match {node*_s} $m] || [string match {node*_e} $m]} { incr n } }
    return $n
}

pack [ttk::frame .f] -fill both -expand 1
set d [Demo new .f]
set T .f.body.t

# Build two folders, each with two sessions; expand as we go.
set f1 [$d insert "" folder f1 {label ProjectOne n 0}]
set f2 [$d insert "" folder f2 {label ProjectTwo n 0}]
check "two roots drawn, invariant clean" 0 [tripped]
$d expand $f1
set s1 [$d insert $f1 session s1 {label alpha n 11}]
set s2 [$d insert $f1 session s2 {label beta  n 22}]
$d expand $f2
set s3 [$d insert $f2 session s3 {label gamma n 33}]
check "sessions under open folders, invariant clean" 0 [tripped]
check "six live marks (2 folders + ... only rendered nodes)" 1 [expr {[live_marks $T] >= 6}]

# A subagent nested under the first session of folder one (middle session: the
# folder end must not be dragged into its child block).
$d expand $s1
set a1 [$d insert $s1 subagent a1 {label worker n 1}]
check "subagent nested, invariant clean" 0 [tripped]

# In-place rewrite of a heading and a session row.
$d node_pset $f1 label "ProjectOne (renamed)"
$d item $f1
$d node_pset $s2 label "beta updated"
$d item $s2
check "in-place item rewrites, invariant clean" 0 [tripped]

# Collapse and re-expand a folder; the body vanishes and comes back clean.
$d collapse $f1
check "collapse folder one, invariant clean" 0 [tripped]
$d expand $f1
check "re-expand folder one, invariant clean" 0 [tripped]

# Hide then unhide a session (reversible filter).
$d hide $s3
check "hide a session, invariant clean" 0 [tripped]
$d unhide $s3
check "unhide a session, invariant clean" 0 [tripped]

# An insert before a sibling seats the row there, in the store and the buffer
# alike: before a right-gravity session, before a left-gravity subagent (whose
# start mark must not swallow the new row), before a hidden sibling (the row
# goes before the next drawn one), before a root, and before a sibling the
# parent does not hold, which appends.
proc line_of {id} { return [lindex [split [$::T index [$::d node_field $id start]] .] 0] }
proc row_text {id} { return [$::T get [$::d node_field $id start] "[$::d node_field $id start] lineend"] }
proc abut {a b} { return [$::T compare [$::d node_field $a end] == [$::d node_field $b start]] }
set s0 [$d insert $f1 session s0 {label first n 0} -pos [list before $s1]]
check "before a session: first in the store" [list $s0 $s1 $s2] [$d node_field $f1 children]
check "and first in the buffer, abutting the sibling" {1 1} \
    [list [expr {[line_of $s0] < [line_of $s1]}] [abut $s0 $s1]]
check "the right-gravity sibling's start stays on its own row" 1 [string match {*alpha*} [row_text $s1]]
set a2 [$d insert $s1 subagent a2 {label helper n 2} -pos [list before $a1]]
check "before a subagent: first in the store" [list $a2 $a1] [$d node_field $s1 children]
check "and first in the buffer, abutting the sibling" {1 1} \
    [list [expr {[line_of $a2] < [line_of $a1]}] [abut $a2 $a1]]
check "the left-gravity sibling's start is re-seated past the new row" 1 [string match {*worker*} [row_text $a1]]
$d hide $s1
set sx [$d insert $f1 session sx {label extra n 4} -pos [list before $s1]]
check "before a hidden sibling: the store has it there" [list $s0 $sx $s1 $s2] [$d node_field $f1 children]
check "and the buffer has it before the next drawn sibling" {1 1} \
    [list [expr {[line_of $sx] < [line_of $s2]}] [abut $sx $s2]]
$d unhide $s1
set f0 [$d insert "" folder f0 {label ProjectZero n 0} -pos [list before $f1]]
check "before a root: first among the roots" [list $f0 $f1 $f2] [$d roots]
check "and on the first line" 1 [line_of $f0]
set sy [$d insert $f1 session sy {label stray n 5} -pos [list before $s3]]
check "before a sibling the parent does not hold: appended" $sy [lindex [$d node_field $f1 children] end]
check "and drawn last under the parent" 1 [expr {[line_of $sy] > [line_of $s1]}]
check "inserts before siblings, invariant clean" 0 [tripped]

# Delete everything; the buffer returns to its empty-baseline mark count.
$d delete $f0
$d delete $a1
$d delete $s1
$d delete $s2
$d delete $s3
$d delete $f1
$d delete $f2
check "all deleted, invariant clean" 0 [tripped]
check "no leaked position marks after empty" 0 [live_marks $T]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
