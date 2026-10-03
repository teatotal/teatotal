#!/usr/bin/env wish9.0
# The budget render_subject is handed is what the row leaves its subject: the
# subject zone less the image the row leads with and its prefix marks, and,
# on a row with trailing marks, less the cluster and a gap. A subject cut to
# it leaves the trailing cluster on its stop, whatever else the row carries.

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file dirname [file normalize [info script]]]]]
foreach md [glob -directory [file join $ROOT modules] -type d *] { ::tcl::tm::path add $md }
package prefer latest
package require streamtree
set ::env(STREAMTREE_AUDIT) 1

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name\n  expected: $expected\n  actual:   $actual"
        incr ::fails
    } else { puts "ok:   $name" }
}

image create photo lead -width 12 -height 12

# Every subject is longer than any budget and is cut to the one it is handed,
# in the font the rows draw in.
oo::class create Budgeted {
    superclass ::streamtree::StreamTree
    variable Text SubjectMax ColGap TrailX Budget
    constructor {parent} {
        my configure -attrs [list \
            [dict create id pinned glyph ★] \
            [dict create id running glyph ● place trail]]
        my setup $parent
        $Text tag configure listed -font [my opt listfont] -wrap none
    }
    method column_spec {} { return {{size Size 9999 right 1}} }
    method cell_values {node} { return {{size 1}} }
    method row_tags {kind} { return listed }
    method row_image {node} {
        return [expr {[my node_pget $node led 0] ? {-image lead -padx 3} : {}}]
    }
    method render_subject {node max} {
        dict set Budget $node $max
        set title [string repeat "a long title " 40]
        return [dict create subject [my truncate_px $title $max [my opt listfont]] tags {} meta_run 0]
    }
    method budget {node} { return [dict get $Budget $node] }
    method zone {} { return $SubjectMax }
    method width {text} { return [font measure [my opt listfont] $text] }
    method before_cluster {text} { return [expr {$TrailX - [my width $text] - $ColGap}] }
    method text {} { return $Text }
}
pack [ttk::frame .f] -fill both -expand 1
set t [Budgeted new .f]
set T [$t text]
update

foreach {name payload} {
    plain {}
    pin   {pinned 1}
    run   {running 1}
    both  {pinned 1 running 1}
    led   {led 1}
    all   {led 1 pinned 1 running 1}
} { set $name [$t insert "" row $name $payload] }
update

set zone [$t zone]
set p [$t width "★ "]
set c [$t before_cluster "●"]
set i [expr {12 + 2 * 3}]

# --- The budget, row by row: each thing the row lays beside its subject
#     comes off it.
check "a bare row is handed the whole zone" $zone [$t budget $plain]
check "a prefix mark comes off the budget" [expr {$zone - $p}] [$t budget $pin]
check "a trailing cluster and its gap come off it" [expr {min($zone, $c)}] [$t budget $run]
check "a prefix mark and a trailing cluster both come off" \
    [expr {min($zone - $p, $c - $p)}] [$t budget $both]
check "an image and its padding come off" [expr {$zone - $i}] [$t budget $led]
check "an image, a prefix mark and a trailing cluster all come off" \
    [expr {min($zone - $i - $p, $c - $i - $p)}] [$t budget $all]

# --- A subject cut to its budget leaves the trailing cluster on its stop:
#     the mark ends at one x on every row, whatever lies ahead of the subject.
proc mark_end {t id} {
    set T [$t text]
    set s [$t node_field $id start]
    lassign [$T bbox [$T search ● $s "$s lineend"]] x _ w
    return [expr {$x + $w}]
}
check "the cluster ends where it does with nothing ahead of the subject" \
    [list [mark_end $t $run] [mark_end $t $run]] [list [mark_end $t $both] [mark_end $t $all]]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
