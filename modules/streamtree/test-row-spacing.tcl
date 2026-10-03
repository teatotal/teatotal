#!/usr/bin/env wish9.0
# A row keeps its spacing inside its line, where its image reaches. With
# row_spacing answered and each image as tall as its row, the text sits the
# asked gaps from the line's edges, the image spans the line top to bottom,
# and one row's line ends where the next begins, so a guide drawn in the
# images runs down the rows unbroken. The placement holds through every lay
# of the row.

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

# The gaps a heading, a row and a note keep, the note with more under it than
# over it. A `level` row leaves the hook at its default and is led by an
# image taller than its text all the same.
set GAPS {folder {14 3} row {6 2} note {1 5}}

# One image per depth and kind, as tall as the kind's row: the text's line
# height plus both gaps.
proc lead {depth kind} {
    set name lead-$depth-$kind
    if {$name ni [image names]} {
        lassign [dict getdef $::GAPS $kind {5 5}] above below
        set extra [expr {$above + $below}]
        image create photo $name -width [expr {12 * ($depth + 1)}] -height [expr {$::LINE + $extra}]
    }
    return $name
}

oo::class create Spaced {
    superclass ::streamtree::StreamTree
    variable Text
    constructor {parent} { my setup $parent }
    method row_spacing {kind} {
        if {[dict exists $::GAPS $kind]} { return [dict get $::GAPS $kind] }
        next $kind
    }
    # Every alignment but baseline, which the placement is not exact under.
    method row_image {node} {
        set kind [my node_field $node kind]
        return [list -image [lead [llength [my ancestors $node]] $kind] \
            -align [dict getdef {folder top row bottom} $kind center]]
    }
    method text {} { return $Text }
}
pack [ttk::frame .f] -fill both -expand 1
set t [Spaced new .f]
set T [$t text]
# The line height of the font the rows draw in, no tag here naming another.
set LINE [font metrics [$T cget -font] -linespace]

set folder [$t insert "" folder f [dict create label "a heading"]]
$t expand $folder
set row   [$t insert $folder row r [dict create label "a row"]]
set note  [$t insert $folder note n [dict create label "a note"]]
set level [$t insert "" level l [dict create label "a level row"]]
set rows  [list $folder $row $note $level]
update

# The px over and under the text of the line that starts at s with an image,
# from the line's edges to the text's.
proc line_gaps {T s} {
    lassign [$T dlineinfo $s] _ ly _ lh
    lassign [$T bbox "$s + 1c"] _ cy _ ch
    return [list [expr {$cy - $ly}] [expr {$ly + $lh - $cy - $ch}]]
}
proc gaps {t id} { return [line_gaps [$t text] [$t node_field $id start]] }
# Where a row's image sits against its line: {0 0} when it starts at the
# line's top and is as tall as the line.
proc span {t id} {
    set T [$t text]
    set s [$t node_field $id start]
    lassign [$T dlineinfo $s] _ ly _ lh
    lassign [$T bbox $s] _ iy _ ih
    return [list [expr {$iy - $ly}] [expr {$ih - $lh}]]
}
proc all_gaps {t rows} { return [lmap id $rows { gaps $t $id }] }

# --- Each row keeps its kind's gaps, the larger above or below; a row under
#     the default sits centred in the taller line.
check "every row keeps its kind's gaps" {{14 3} {6 2} {1 5} {5 5}} [all_gaps $t $rows]

# --- The image spans its line, and the lines stack with nothing between
#     them: what lets a guide drawn in the images run unbroken.
check "every row's image spans its line" {{0 0} {0 0} {0 0} {0 0}} [lmap id $rows { span $t $id }]
set joined 1
foreach a [lrange $rows 0 end-1] b [lrange $rows 1 end] {
    lassign [$T dlineinfo [$t node_field $a start]] _ ay _ ah
    lassign [$T dlineinfo [$t node_field $b start]] _ by
    if {$ay + $ah != $by} { set joined 0 }
}
check "each line ends where the next begins" 1 $joined

# --- The placement holds through every lay: a row rewritten in place, a
#     folder shut and opened, a rebuild.
foreach id $rows { $t item $id }
update
check "item keeps the gaps" {{14 3} {6 2} {1 5} {5 5}} [all_gaps $t $rows]
$t collapse $folder
$t expand $folder
update
check "a row drawn again by expand keeps its gaps" {{6 2} {1 5}} [all_gaps $t [list $row $note]]
$t rebuild
update
check "rebuild keeps the gaps" {{14 3} {6 2} {1 5} {5 5}} [all_gaps $t $rows]

# --- A loose line the host lays takes the same placement from its newline,
#     emitted under a tag whose -offset is the gap above less the gap below.
image create photo loose -width 12 -height [expr {$LINE + 9 + 2}]
$T tag configure looseend -offset [expr {9 - 2}]
$t batch {
    set m [$t append_open $note]
    $t emit_image $m -image loose
    $t emit $m "a loose line" {}
    $t emit $m "\n" looseend
    $t append_close $note $m
}
update
check "a loose line keeps the gaps its newline's offset asks" {9 2} \
    [line_gaps $T [$T index "[$t node_field $note start] + 1 line linestart"]]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
