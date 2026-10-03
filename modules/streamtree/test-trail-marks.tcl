#!/usr/bin/env wish9.0
# A glyphed bool placed trail draws its mark right-aligned at the subject
# zone's end rather than ahead of the subject: every row and the header tab
# to the trailing stop before their cells, marks or none, so the cells keep
# their columns; the subject's budget shrinks by the row's own marks; and the
# declaration is refused where it cannot be drawn.

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

# A prefix mark, trailing marks, one column; the budget each row was
# handed is kept for the assertions.
oo::class create Marked {
    superclass ::streamtree::StreamTree
    variable Text SubjectMax ColGap TrailX Budget
    constructor {parent} {
        my configure -attrs [list \
            [dict create id pinned glyph ★] \
            [dict create id running glyph ● place trail] \
            [dict create id flagged glyph ◆ place trail]]
        my setup $parent
    }
    method subject_label {} { return "Name" }
    method column_spec {} { return {{size Size 9999 right 1}} }
    method cell_values {node} { return [list [list size [my node_pget $node size 0]]] }
    method render_subject {node max} {
        dict set Budget $node $max
        return [dict create subject [my node_pget $node label] tags {} meta_run 1]
    }
    method budget {node} { return [dict get $Budget $node] }
    method subject_max {} { return $SubjectMax }
    method trail_budget {text} {
        return [expr {min($SubjectMax, $TrailX - [font measure [my opt listfont] $text] - $ColGap)}]
    }
    method text {} { return $Text }
}
pack [ttk::frame .f] -fill both -expand 1
set t [Marked new .f]
set T [$t text]
update

set plain [$t insert "" row p [dict create label "plain" size 1]]
set run   [$t insert "" row r [dict create label "running" size 2 running 1]]
set both  [$t insert "" row b [dict create label "both" size 3 running 1 pinned 1]]
set two   [$t insert "" row w [dict create label "two" size 4 flagged 1 running 1]]
update

proc row {t id} {
    set T [$t text]
    return [$T get [$t node_field $id start] "[$t node_field $id start] lineend"]
}
# --- The row's text: the subject, a tab to the trailing stop, the marks,
#     then the cells behind their own tabs; a row with no mark still tabs.
check "a row with no mark tabs to the trailing stop empty" "plain\t\t1" [row $t $plain]
check "a trailing mark sits behind that tab" "running\t●\t2" [row $t $run]
check "a prefix mark stays ahead of the subject" "★ both\t●\t3" [row $t $both]
check "trailing marks cluster in declaration order" "two\t●◆\t4" [row $t $two]

# --- The marks keep their attribute tags, and the muted run starts at the
#     first cell, not at the marks.
set rs [$t node_field $run start]
check "the trailing mark carries its attribute tag" "●" [$T get {*}[lrange [$T tag ranges attr-running] 0 1]]
check "the meta run starts at the first cell" [$T index "$rs + 9c"] [lindex [$T tag ranges meta] 2]

# --- The header and every row share the stops, the trailing one first.
check "the header tabs to the trailing stop before its columns" "Name\t\tSize ▼" \
    [.f.body.hdr get 1.0 "1.0 lineend"]
set tabs [$T cget -tabs]
check "two right stops, the trailing one first" {right right} [list [lindex $tabs 1] [lindex $tabs 3]]
check "the trailing stop lies left of the column's" 1 [expr {[lindex $tabs 0] < [lindex $tabs 2]}]

# --- The cells keep their column whether or not a row carries a mark, and
#     the mark ends a gap short of the cell.
proc cell_x {t id} {
    set T [$t text]
    return [lindex [$T bbox "[$t node_field $id start] lineend - 1c"] 0]
}
check "a marked row's cell sits where an unmarked row's does" [cell_x $t $plain] [cell_x $t $run]
lassign [$T bbox "$rs + 8c"] mx _ mw
check "the mark ends left of the cell" 1 [expr {$mx + $mw < [cell_x $t $run]}]

# --- The subject's budget: the whole zone on a row with no mark, less the
#     mark and a gap on a row with one.
check "an unmarked row keeps the whole subject zone" [$t subject_max] [$t budget $plain]
check "a marked row's budget stops short of its marks" [$t trail_budget "●"] [$t budget $run]

# --- A flag that changes redraws through item like any row content.
$t node_pset $run running 0
$t item $run
check "a mark turned off leaves the row on the next lay" "running\t\t2" [row $t $run]
$t node_pset $plain running 1
$t item $plain
check "a mark turned on joins the row on the next lay" "plain\t●\t1" [row $t $plain]

# --- The declaration is refused where its mark cannot be drawn.
set u [::streamtree::StreamTree new]
check "an unknown place is refused" 1 [catch {$u configure -attrs [list [dict create id x glyph ● place middle]]}]
check "trail without a glyph is refused" 1 [catch {$u configure -attrs [list [dict create id x place trail]]}]
check "trail on an enum is refused" 1 [catch {$u configure -attrs [list [dict create id x kind enum glyph ● place trail]]}]
check "a glyphed bool placed trail is accepted" 0 [catch {$u configure -attrs [list [dict create id x glyph ● place trail]]}]
check "and so is one placed prefix by name" 0 [catch {$u configure -attrs [list [dict create id x glyph ● place prefix]]}]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
