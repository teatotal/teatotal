#!/usr/bin/env wish9.0
# Groups over the StreamDoc base class: a run of regions and chrome under one
# header line, folded and unfolded, nested, streamed into while folded,
# revealed into, left alone by fold_all and expand_all, emptied by reset,
# and opened by a host that starts at reset. Audit gate on throughout; the
# last check asserts it never tripped.

package require Tcl 9
package require Tk

proc bgerror {msg} {
    puts "FAIL: background error: $msg\n$::errorInfo"
    incr ::fails
}

set ROOT [file dirname [file dirname [file dirname [file normalize [info script]]]]]
foreach md [glob -directory [file join $ROOT modules] -type d *] { ::tcl::tm::path add $md }
package require streamdoc 1.4
set ::env(STREAMDOC_AUDIT) 1

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name\n  expected: $expected\n  actual:   $actual"
        incr ::fails
    } else { puts "ok:   $name" }
}
proc tripped {} { return [expr {[info exists ::STREAMDOC_AUDIT_TRIPPED] ? 1 : 0}] }

pack [ttk::frame .f] -fill both -expand 1
set d [::streamdoc::StreamDoc new]
oo::objdefine $d method summary_text {payload} {
    set n [dict getdef $payload notes 0]
    if {!$n} { return "" }
    return "· $n note[expr {$n == 1 ? "" : "s"}]"
}
$d setup .f
set T .f.text
$T configure -width 46 -height 30
update

# vis: the displayed chars from a pattern's hit to its line's end, 0 while
# the line is elided; -1 when the pattern is nowhere.
proc at {pat} { return [$::T search -elide $pat 1.0] }
proc vis {pat} {
    set i [at $pat]
    if {$i eq ""} { return -1 }
    return [$::T count -displaychars $i "$i lineend"]
}
proc shown {pat} { return [expr {[vis $pat] > 0}] }
proc has {pat} { return [expr {[at $pat] ne ""}] }

proc chrome {text} {
    $::d batch {
        set m [$::d append_open]
        $::d emit $m $text {}
        $::d append_close $m
    }
}
# A group header is chrome, emitted right after group_open.
proc gopen {head {payload {}}} {
    $::d batch {
        set g [$::d group_open $payload]
        set m [$::d append_open]
        $::d emit $m "▾ $head\n" {}
        $::d append_close $m
    }
    return $g
}
proc region {head body {payload {}} {detail ""}} {
    $::d batch {
        set n [$::d region_open $payload]
        set m [$::d append_open]
        $::d emit $m "▾ $head\n$body" {}
        if {$detail ne ""} { $::d emit $m $detail [list [$::d detail_tag $n]] }
        $::d append_close $m
        $::d region_close
    }
    return $n
}
proc gfolded {g} { return [dict get [$::d group_info $g] folded] }

# ---- open, header, regions, close -----------------------------------------
chrome "preamble chrome\n"
set g0 [gopen "Group zero" [dict create name zero]]
check "group_open returns index 0" 0 $g0
check "group_count counts the open group" 1 [$d group_count]
check "an open group reads open" 1 [dict get [$d group_info $g0] open]
check "an open group's end rides the tail" [$T index "end - 1 chars"] \
    [dict get [$d group_info $g0] end]
set r0 [region "Alpha" "alpha body\n" [dict create notes 1] "alpha detail\n"]
chrome "between chrome\n"
set r1 [region "Beta" "beta body\n"]
$d group_close
chrome "after zero\n"
set info [$d group_info $g0]
check "group_close seals the group" 0 [dict get $info open]
check "the group starts at its header" [at "▾ Group zero"] [dict get $info start]
check "the group ends where the chrome after it starts" [at "after zero"] [dict get $info end]
check "the group keeps its payload" [dict create name zero] [dict get $info payload]
check "region numbering ignores groups" {0 1} [list $r0 $r1]
check "a group header is chrome to region_at" -1 [$d region_at [at "Group zero"]]
check "group_at on its header resolves to the group" $g0 [$d group_at [at "Group zero"]]
check "group_at on a body line" $g0 [$d group_at [at "beta body"]]
check "group_at before the group" -1 [$d group_at [at "preamble"]]
check "group_at after the group" -1 [$d group_at [at "after zero"]]
check "groups_at on a body line" [list $g0] [$d groups_at [at "between chrome"]]
check "groups_at on the header is empty" {} [$d groups_at [at "Group zero"]]

# ---- fold and unfold ----------------------------------------------------------
$d detail_show $r0
$d group_fold $g0
check "a folded group hides a region header" 0 [vis "Alpha"]
check "a folded group hides an unfolded region's body" 0 [vis "alpha body"]
check "a folded group hides shown detail" 0 [vis "alpha detail"]
check "a folded group hides a summary line" 0 [vis "· 1 note"]
check "a folded group hides its chrome" 0 [vis "between chrome"]
check "a folded group keeps its header shown" 1 [shown "Group zero"]
check "the chrome after a folded group stays shown" 1 [shown "after zero"]
check "the header glyph flips closed" 1 [has "▸ Group zero"]
check "group_info reads folded" 1 [gfolded $g0]
check "a group fold leaves the regions' states" {0 1} [list [$d folded $r0] [$d shown $r0]]
$d group_unfold $g0
check "unfold restores the region header" 1 [shown "Alpha"]
check "unfold restores the body" 1 [shown "alpha body"]
check "unfold restores shown detail" 1 [shown "alpha detail"]
check "unfold restores the chrome" 1 [shown "between chrome"]
check "the header glyph flips open" 1 [has "▾ Group zero"]
$d detail_hide $r0
$d fold $r1
$d group_toggle $g0
check "group_toggle folds" 1 [gfolded $g0]
$d group_toggle $g0
check "group_toggle unfolds" 0 [gfolded $g0]
check "a region folded before the group fold stays folded" 0 [vis "beta body"]
check "hidden detail stays hidden" 0 [vis "alpha detail"]
$d unfold $r1

# ---- nested groups -------------------------------------------------------------
set go [gopen "Outer"]
set ra [region "Outer first" "outer body\n"]
set gi [gopen "Inner"]
set rb [region "Inner region" "inner body\n"]
$d group_close
set rc [region "Outer last" "outer tail\n"]
$d group_close
chrome "after outer\n"
check "group_at on the inner header" $gi [$d group_at [at "Inner"]]
check "group_at on an inner body line is the inner group" $gi [$d group_at [at "inner body"]]
check "group_at on an outer body line is the outer group" $go [$d group_at [at "outer tail"]]
check "groups_at two deep, outermost first" [list $go $gi] [$d groups_at [at "inner body"]]
check "groups_at on the inner header holds only the outer" [list $go] [$d groups_at [at "Inner"]]
check "the inner group ends inside the outer" 1 [$T compare \
    [dict get [$d group_info $gi] end] < [dict get [$d group_info $go] end]]

$d group_fold $go
check "a folded outer hides the unfolded inner's header" 0 [vis "Inner"]
check "a folded outer hides the unfolded inner's region" 0 [vis "inner body"]
check "the inner group keeps its unfolded state" 0 [gfolded $gi]
$d group_unfold $go
check "unfolding the outer shows the unfolded inner" 1 [shown "inner body"]

$d group_fold $gi
$d fold $rb
check "a folded inner keeps its header shown" 1 [shown "Inner"]
check "a folded inner hides its region" 0 [vis "Inner region"]
$d group_fold $go
check "a folded outer hides a folded inner's header" 0 [vis "Inner"]
$d group_unfold $go
check "unfolding the outer shows the inner header" 1 [shown "Inner"]
check "unfolding the outer leaves the inner folded" 1 [gfolded $gi]
check "the inner's region stays hidden" 0 [vis "Inner region"]
$d group_unfold $gi
check "unfolding the inner shows its region header" 1 [shown "Inner region"]
check "the region folded inside stays folded" 0 [vis "inner body"]
$d unfold $rb

# ---- streaming into a folded open group ------------------------------------------
set gs [gopen "Streaming"]
region "Before fold" "before body\n"
$d group_fold $gs
$d batch {
    set rs [$d region_open [dict create notes 0]]
    set m [$d append_open]
    $d emit $m "▾ Streamed region\nstreamed body\n" {}
    $d append_close $m
}
check "a region opened in a folded open group hides its header" 0 [vis "Streamed region"]
check "a region opened in a folded open group hides its body" 0 [vis "streamed body"]
$d payload_set $rs [dict create notes 2]
$d batch {
    set m [$d append_open]
    $d emit $m "more streamed\n" {}
    $d append_close $m
}
check "a line streamed later stays hidden" 0 [vis "more streamed"]
check "its summary line stays hidden" 0 [vis "· 2 notes"]
$d payload_set $rs [dict create notes 3]
$d summary_sync
check "a summary re-synced outside the door stays hidden" 0 [vis "· 3 notes"]
$d region_close
check "the summary rewritten at region_close stays hidden" 0 [vis "· 3 notes"]
chrome "streamed chrome\n"
check "chrome in a folded open group stays hidden" 0 [vis "streamed chrome"]
set gn [gopen "Nested late"]
region "Late region" "late body\n"
$d group_close
check "a group nested into a folded open group stays hidden" 0 [vis "Nested late"]
check "and its region" 0 [vis "late body"]
$d group_close
check "group_close keeps it folded" 1 [gfolded $gs]
check "the streamed body stays hidden after close" 0 [vis "streamed body"]
chrome "after streaming\n"
check "chrome after the closed folded group shows" 1 [shown "after streaming"]
$d group_unfold $gs
check "unfold shows the streamed region" 1 [shown "streamed body"]
check "unfold shows its summary" 1 [shown "· 3 notes"]
check "unfold shows the nested group's region" 1 [shown "late body"]

# ---- reveal ------------------------------------------------------------------------
$d group_fold $gi
$d group_fold $go
$d reveal [at "inner body"]
update
check "reveal unfolds the outer group" 0 [gfolded $go]
check "reveal unfolds the inner group" 0 [gfolded $gi]
check "reveal shows the target" 1 [shown "inner body"]
check "reveal lands the target in the viewport" 1 [expr {[$T bbox [at "inner body"]] ne ""}]

$d group_fold $gi
$d group_fold $go
$d reveal [at "Inner"]
update
check "reveal on a header unfolds the group around it" 0 [gfolded $go]
check "reveal on a header leaves its own group folded" 1 [gfolded $gi]
check "the revealed header shows" 1 [shown "Inner"]
check "the header's group body stays hidden" 0 [vis "Inner region"]

# ---- fold_all and expand_all are region-only --------------------------------------
$d group_fold $go
$d fold_all
check "fold_all leaves a folded group folded" 1 [gfolded $go]
check "fold_all leaves a folded inner group folded" 1 [gfolded $gi]
check "fold_all leaves an unfolded group unfolded" 0 [gfolded $g0]
check "fold_all folds the regions" 1 [$d folded $r0]
$d expand_all
check "expand_all leaves a folded group folded" 1 [gfolded $go]
check "expand_all unfolds the regions" 0 [$d folded $rb]
check "a region expand_all unfolded stays hidden in its folded group" 0 [vis "outer body"]
check "an unfolded group shows its regions after expand_all" 1 [shown "beta body"]

# ---- group_close with a region still open inside -----------------------------------
set ge [gopen "Erring"]
$d batch {
    $d region_open {}
    set m [$d append_open]
    $d emit $m "▾ unfinished\n" {}
    $d append_close $m
}
check "group_open with a region open errors" 1 [catch {$d group_open {}}]
check "group_close with a region open inside errors" 1 [catch {$d group_close} msg]
check "the error names the open region" 1 [string match "region * is still open*" $msg]
check "the failed close leaves the group open" 1 [dict get [$d group_info $ge] open]
$d region_close
$d group_close
check "closing the region first lets the group close" 0 [dict get [$d group_info $ge] open]
check "group_close with no group open is a no-op" "" [$d group_close]

# ---- reset -------------------------------------------------------------------------
check "groups have marks and tags before reset" 1 \
    [expr {[llength [lsearch -all [$T mark names] g#*]] > 0
           && [llength [lsearch -all [$T tag names] G#*]] > 0}]
$d reset
check "reset empties the group store" 0 [$d group_count]
check "reset drops the group marks" {} [lsearch -all -inline [$T mark names] g#*]
check "reset drops the group tags" {} [lsearch -all -inline [$T tag names] G#*]
set g [gopen "Fresh"]
check "a group after reset takes index 0" 0 $g
$d group_close

# ---- a host that starts at reset ----------------------------------------------------
# Its own text widget in Text, no setup: reset seeds the state.
toplevel .t2
pack [text .t2.text -width 30 -height 5]
set b [::streamdoc::StreamDoc new]
set [info object namespace $b]::Top .t2
set [info object namespace $b]::Text .t2.text
$b reset
$b batch {
    set g [$b group_open {}]
    set m [$b append_open]
    $b emit $m "▾ bespoke group\n" {}
    $b append_close $m
}
$b batch {
    $b region_open {}
    set m [$b append_open]
    $b emit $m "▾ bespoke region\nbespoke body\n" {}
    $b append_close $m
    $b region_close
}
$b group_close
check "a host that starts at reset opens a group" 0 $g
$b group_fold $g
check "and folds it" 0 [.t2.text count -displaychars \
    [.t2.text search -elide "bespoke body" 1.0] "[.t2.text search -elide "bespoke body" 1.0] lineend"]

check "audit gate never tripped" 0 [tripped]
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
