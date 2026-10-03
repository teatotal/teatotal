#!/usr/bin/env wish9.0
# The image a row leads with (the row_image hook) is laid on every lay of
# the row, carries the row's tags, shifts every tagged range past itself and
# comes off the subject's budget; emit_image lays one into loose content
# under a row, inside the node's region.

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

# A guide image per depth, 12 px per level, so a nested row leads with one
# and a root does not.
foreach d {1 2} {
    image create photo guide$d -width [expr {12 * $d}] -height 20
}

# A tree whose nested rows lead with a guide, one column, and a subject
# tagged over its first three characters; the budget each row was handed
# is kept for the assertions.
oo::class create Guided {
    superclass ::streamtree::StreamTree
    variable Text SubjectMax Budget
    constructor {parent} { my setup $parent }
    method column_spec {} { return {{size Size 9999 right 1}} }
    method cell_values {node} { return [list [list size [my node_pget $node size 0]]] }
    method cell_tag {node col} { return sizecell }
    method row_image {node} {
        set d [llength [my ancestors $node]]
        if {$d == 0} { return [list] }
        return [list -image guide$d -align center -padx 2]
    }
    method render_subject {node max} {
        dict set Budget $node $max
        return [dict create subject [my node_pget $node label] tags {{head 0 3}} meta_run 1]
    }
    method budget {node} { return [dict get $Budget $node] }
    method subject_max {} { return $SubjectMax }
    method text {} { return $Text }
}
pack [ttk::frame .f] -fill both -expand 1
set t [Guided new .f]
set T [$t text]
update

set root  [$t insert "" folder r [dict create label "root row" size 1]]
set child [$t insert $root row c [dict create label "child row" size 2]]
$t expand $root

# --- A nested row leads with its image, at the node's start, under the
#     node's tag; a root row has none.
proc images_in {t id} {
    set T [$t text]
    set out [list]
    foreach {k v i} [$T dump -image [$t node_field $id start] [$t node_field $id end]] {
        lappend out [regsub {#\d+$} $v ""]
    }
    return $out
}
proc image_count {t} { return [expr {[llength [[$t text] dump -image 1.0 end]] / 3}] }
check "the root row leads with no image" 0 [llength [$T dump -image [$t node_field $root start] "[$t node_field $root start] lineend"]]
check "the nested row leads with its depth's image" guide1 [images_in $t $child]
set cs [$t node_field $child start]
check "the image sits at the node's start" 1 [expr {[llength [$T dump -image $cs "$cs + 1c"]] > 0}]
check "the image carries the node's tag" 1 [expr {[$t node_field $child tag] in [$T tag names $cs]}]

# --- The ranges the build tags land on the text, one index past the image:
#     the subject's head tag starts after the image and the cell tag covers
#     the cell's own value.
check "the subject's tag range starts past the image" [$T index "$cs + 1c"] [lindex [$T tag ranges head] 2]
set cell [$T get {*}[lrange [$T tag ranges sizecell] 2 3]]
check "the cell tag covers the cell's value" 2 $cell

# --- The budget handed to render_subject is the subject zone less the image
#     and its padding; a root keeps the whole zone.
check "a root row's budget is the subject zone" [$t subject_max] [$t budget $root]
check "a nested row's budget is less the image and its padding" \
    [expr {[$t subject_max] - 12 - 4}] [$t budget $child]

# --- Every lay of the row lays the image again: item, relayout, rebuild.
$t item $child
check "item lays the image again" guide1 [images_in $t $child]
check "and leaves the one image, not two" 1 [image_count $t]
$t rebuild
check "rebuild lays the image again" guide1 [images_in $t $child]
$t relayout
check "relayout lays the image again" guide1 [images_in $t $child]
check "the tag range still starts past the image" \
    [$T index "[$t node_field $child start] + 1c"] [lindex [$T tag ranges head] 2]

# --- Depth is the hook's to read: a row moved under a deeper parent leads
#     with the deeper image.
set inner [$t insert $root folder i [dict create label "inner" size 3]]
$t expand $inner
$t move $child $inner
check "a row moved deeper leads with the deeper image" guide2 [images_in $t $child]

# --- emit_image lays loose content inside a node's region, carrying the
#     node's end mark forward like emit and emit_window do, and it goes
#     with the node.
set m [$t append_open $child]
lassign [$t emit_image $m -image guide1] i0 i1
$t emit $m "note\n" {}
$t append_close $child $m
check "emit_image returns the range it laid" 1 [$T compare "$i0 + 1c" == $i1]
check "the emitted image is inside the node's region" 1 \
    [expr {[$T compare $i0 >= [$t node_field $child start]] && [$T compare $i1 <= [$t node_field $child end]]}]
check "the emitted image counts among the node's" {guide2 guide1} [images_in $t $child]
$t delete $child
check "the node's images go with it, the inner folder's stays" 1 [image_count $t]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
