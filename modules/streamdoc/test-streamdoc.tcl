#!/usr/bin/env wish9.0
# A minimal host over the StreamDoc base class: chrome and regions through the
# content door, the two elide layers, summary sync while a region streams,
# rewind, reveal onto an elided target, the anchor contract (a parked
# reader unmoved by appends below; the autofollow latch at the tail), the
# door query, the on_reveal hook and the find bar. Audit gate on throughout;
# the last check asserts it never tripped.

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file dirname [file normalize [info script]]]]]
foreach md [glob -directory [file join $ROOT modules] -type d *] { ::tcl::tm::path add $md }
package require -exact streamdoc 1.2a1
set ::env(STREAMDOC_AUDIT) 1

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name\n  expected: $expected\n  actual:   $actual"
        incr ::fails
    } else { puts "ok:   $name" }
}
proc tripped {} { return [expr {[info exists ::STREAMDOC_AUDIT_TRIPPED] ? 1 : 0}] }

oo::class create Feed {
    superclass ::streamdoc::StreamDoc
    method summary_text {payload} {
        set n [dict getdef $payload notes 0]
        if {!$n} { return "" }
        return "· $n note[expr {$n == 1 ? "" : "s"}]"
    }
}

pack [ttk::frame .f] -fill both -expand 1
set d [Feed new]
$d setup .f
set T .f.text
$T configure -width 46 -height 10
update

# search with -elide so elided targets still resolve; count -displaychars
# then says whether the line is actually displayed (0 = fully elided).
proc at {pat} { return [$::T search -elide $pat 1.0] }
proc vis {pat} {
    set i [at $pat]
    if {$i eq ""} { return -1 }
    return [$::T count -displaychars $i "$i lineend"]
}
proc has {pat} { return [expr {[at $pat] ne ""}] }

# ---- chrome before any region -------------------------------------------
$d batch {
    set m [$d append_open]
    $d emit $m "prologue chrome\n" {}
    $d emit_window $m -window [ttk::label $T.w0 -text badge]
    $d emit $m "\n" {}
    $d append_close $m
}
check "chrome belongs to no region" -1 [$d region_at [at "prologue"]]
check "no region yet" 0 [$d region_count]

# ---- a region with detail and a summary ----------------------------------
$d batch {
    set r0 [$d region_open [dict create notes 2]]
    set m [$d append_open]
    $d emit $m "▾ First region\n" {}
    $d emit $m "visible body line\n" {}
    $d emit $m "hidden note A\nhidden note B\n" [list [$d detail_tag $r0]]
    $d append_close $m
    $d region_close
}
update
check "region takes index 0" 0 $r0
check "header resolves to its region" 0 [$d region_at [at "First region"]]
check "summary line written from the hook" 1 [has "· 2 notes"]
check "summary carries the default styling tag" 1 \
    [expr {"summary" in [$T tag names [at "· 2 notes"]]}]
check "detail lines are elided by default" 0 [vis "hidden note A"]
check "body line is displayed" 17 [vis "visible body line"]

$d detail_show 0
check "detail_show reveals the notes" 13 [vis "hidden note A"]
check "summary glyph follows detail state" "▾" [$T get "[at {· 2 notes}] -2c"]
$d detail_hide 0
check "detail_hide re-elides" 0 [vis "hidden note A"]
check "summary glyph back to closed" "▸" [$T get "[at {· 2 notes}] -2c"]

$d fold 0
check "fold elides the body" 0 [vis "visible body line"]
check "fold elides the summary" 0 [vis "· 2 notes"]
check "fold leaves the header visible" 1 [expr {[vis "First region"] > 0}]
check "header glyph flips closed" 1 [has "▸ First region"]
$d unfold 0
check "unfold restores the body" 17 [vis "visible body line"]
check "unfold keeps detail hidden" 0 [vis "hidden note A"]
check "header glyph flips open" 1 [has "▾ First region"]
check "no audit trip after fold/detail cycling" 0 [tripped]

# ---- streaming into an open region: summary pop and re-append ------------
$d batch {
    set r1 [$d region_open [dict create notes 0]]
    set m [$d append_open]
    $d emit $m "▾ Second region\nalpha\n" {}
    $d append_close $m
}
check "empty summary phrase takes no summary line" 0 [has "0 note"]
$d payload_set $r1 [dict create notes 1]
$d batch {
    set m [$d append_open]
    $d emit $m "beta\n" {}
    $d append_close $m
}
check "summary appears once the payload counts" 1 [has "· 1 note"]
$d batch {
    set m [$d append_open]
    $d emit $m "gamma\n" {}
    $d append_close $m
}
set doc [$T get 1.0 end]
check "streamed line lands above the summary" 1 \
    [expr {[string first "gamma" $doc] < [string first "· 1 note" $doc]}]
check "popped summary re-appends, not duplicates" 1 [regexp -all {· 1 note} $doc]

# ---- rewind: provisional tail deleted, caller re-emits --------------------
$d batch {
    set m [$d append_open]
    set sp [$d savepoint]
    $d emit $m "provisional tail\n" {}
    $d rewind $sp
    $d emit $m "final tail\n" {}
    $d append_close $m
    $d discard $sp
}
check "rewind removed the provisional emit" 0 [has "provisional tail"]
check "the re-emit landed" 1 [has "final tail"]
check "rewind kept the summary trailing" 1 \
    [expr {[string first "final tail" [$T get 1.0 end]] \
         < [string first "· 1 note" [$T get 1.0 end]]}]
$d region_close
check "close leaves no open region" -1 [$d live]
check "no audit trip after streaming and rewind" 0 [tripped]

# ---- reveal onto an elided target -----------------------------------------
$d fold 0
set idx [at "hidden note A"]
$d reveal $idx
update
check "reveal unfolds the target's region" 1 [expr {[vis "visible body line"] > 0}]
check "reveal shows the detail holding the target" 1 [expr {[vis "hidden note A"] > 0}]
check "reveal lands the target in the viewport" 1 [expr {[$T bbox $idx] ne ""}]

# ---- anchor contract --------------------------------------------------------
for {set i 0} {$i < 25} {incr i} {
    $d batch {
        $d region_open [dict create]
        set m [$d append_open]
        $d emit $m "▾ filler $i\nfiller body $i\n" {}
        $d append_close $m
        $d region_close
    }
}
update
$T yview moveto 0.35
update
set before [$T index @0,0]
$d batch {
    $d region_open [dict create]
    set m [$d append_open]
    $d emit $m "▾ below the fold\nmore content\n" {}
    $d append_close $m
    $d region_close
}
update
check "a parked reader's viewport survives appends below" $before [$T index @0,0]
check "the parked reader is not dragged to the tail" 1 \
    [expr {[lindex [$T yview] 1] < 0.999}]

set ::at ""
bind .f <<AtBottom>>   {set ::at bottom}
bind .f <<LeftBottom>> {set ::at away}
$d configure -autofollow 1
$d follow
update
check "<<AtBottom>> fires on reaching the tail" bottom $::at
$d batch {
    $d region_open [dict create]
    set m [$d append_open]
    $d emit $m "▾ latched arrival\nits body\n" {}
    $d append_close $m
    $d region_close
}
update
check "the autofollow latch keeps the tail in view" 1 \
    [expr {[lindex [$T yview] 1] >= 0.999}]
$T yview moveto 0
update
check "<<LeftBottom>> fires on scrolling away" away $::at

# ---- reveal alignment ------------------------------------------------------
# From below, `top` puts the target's line on the top edge; in the last
# screenful it scrolls as far as the widget goes, the target in view.
$T yview moveto 1
update
set idx [at "hidden note A"]
$d reveal $idx top
update
check "reveal top puts the target's line on the top edge" \
    [$T index "$idx linestart"] [$T index "@0,0 linestart"]
$T yview moveto 0
update
set last [$T index "end-2l linestart"]
$d reveal $last top
update
check "reveal top in the last screenful stops at the end" 1 \
    [expr {[lindex [$T yview] 1] >= 0.999}]
check "reveal top in the last screenful shows the target" 1 \
    [expr {[$T bbox $last] ne ""}]
check "reveal rejects an unknown align" 1 [catch {$d reveal $idx middle}]

# ---- door -------------------------------------------------------------------
check "door errors with no door open" 1 [catch {$d door} msg]
check "door's error says so" "no door is open" $msg
$d batch {
    set m [$d append_open]
    set inside [$d door]
    $d append_close $m
}
check "door returns the open door's mark" $m $inside
check "door errors once the door closes" 1 [catch {$d door}]

# ---- find: a second document with every find hook overridden ----------------
# on_reveal records the target region's fold state and the view at hook time.
oo::class create Finder {
    superclass Feed
    variable Text
    method on_reveal {idx} {
        set n [my region_at $idx]
        lappend ::revealed [dict create folded [expr {$n >= 0 ? [my folded $n] : -1}] \
            yview [$Text yview]]
    }
    method find_extra {term nocase} { return $::extra }
    method find_bound {} { return $::bound }
    method on_find_stepped {i} { lappend ::stepped $i }
    method find_cleared {} { incr ::cleared }
}
set ::extra {}
set ::bound end
set ::stepped {}
set ::cleared 0

toplevel .t2
pack [ttk::frame .t2.f] -fill both -expand 1
set g [Finder new]
$g setup .t2.f
set T2 .t2.f.text
$T2 configure -width 40 -height 6
proc fv {name} { return [set [info object namespace $::g]::$name] }
proc fset {name val} { set [info object namespace $::g]::$name $val }
proc at2 {pat} { return [$::T2 search -elide $pat 1.0] }
proc apple {pat} { return [$::T2 index "[at2 $pat] +[string first apple $pat]c"] }
proc lit {idx} { return [expr {"find" in [$::T2 tag names $idx]}] }

$g batch {
    set m [$g append_open]
    $g emit $m "intro: Apple pie\n" {}
    $g append_close $m
    set r [$g region_open [dict create notes 1]]
    set m [$g append_open]
    $g emit $m "▾ Fruit\napple one\na note in the body\n" {}
    $g emit $m "hidden apple two\n" [list [$g detail_tag $r]]
    $g append_close $m
    $g region_close
    set r [$g region_open [dict create]]
    set m [$g append_open]
    $g emit $m "▾ Veg\n" {}
    for {set i 0} {$i < 30} {incr i} { $g emit $m "filler $i\n" {} }
    $g emit $m "carrot apple\n" {}
    $g append_close $m
    $g region_close
    set m [$g append_open]
    $g emit $m "END apple\n" {}
    $g append_close $m
}
$g fold 0
update

check "FindNocase defaults to 1" 1 [fv FindNocase]
set hits [$g collect apple 1]
check "collect finds every hit, case folded" 5 [llength $hits]
check "collect returns hits in document order" \
    [list [at2 Apple] [at2 "apple one"] [at2 "apple two"] [apple "carrot apple"] [apple "END apple"]] \
    [lmap h $hits { $T2 index $h }]
check "collect tags a hit in a folded region" 1 [lit [at2 "apple one"]]
check "collect tags a hit in hidden detail" 1 [lit "[at2 {hidden apple}] +7c"]
check "collect leaves the folded region folded" 1 [$g folded 0]
check "collect is case-sensitive when asked" 4 [llength [$g collect apple 0]]

set notes [$g collect note 1]
check "collect skips a hit on a chrome tag (the summary)" \
    [list [$T2 index "[at2 {a note}] +2c"]] $notes
check "the skipped summary hit is not lit" 0 [lit "[at2 {· 1 note}] +4c"]
check "collect keeps an earlier collect's find tags" 1 [lit [apple "carrot apple"]]

$T2 mark set x#0 1.0
$T2 mark set x#1 [$T2 index "[at2 {carrot apple}] linestart"]
set ::extra [list [list x#1 "excerpt one"] [list x#0 "excerpt zero"]]
set hits [$g collect apple 1]
check "find_extra hits merge into document order" 1 \
    [expr {[lindex $hits 0] eq "x#0" && [lsearch $hits x#1] == 4}]
check "find_extra hits count in the result" 7 [llength $hits]
check "find_excerpt returns the find_extra excerpt" "excerpt one" [$g find_excerpt x#1]
check "find_excerpt defaults to the hit's line" "carrot apple" [$g find_excerpt [apple "carrot apple"]]
set ::extra {}

set ::bound [$T2 index "[at2 {END apple}] linestart"]
check "find_bound stops the text search" 4 [llength [$g collect apple 1]]
set ::bound end

$g collect_matches carrot
check "collect_matches removes the earlier find tags" 0 [lit [at2 "apple one"]]
check "collect_matches sets FindMatches" [list [at2 carrot]] [fv FindMatches]
check "collect_matches leaves no hit shown" -1 [fv FindCur]
check "collect_matches updates the readout" "1 of 1" [fv FindPos]

# Stepping: the term in the entry is new, so find_next recollects.
$g fold 0
$g fold 1
$T2 yview moveto 0
update
fset FindVar apple
set ::revealed {}
$g find_next
check "find_next recollects a changed term" 5 [llength [fv FindMatches]]
check "find_next shows the first hit" "1 of 5" [fv FindPos]
check "on_find_stepped gets the hit" 0 [lindex $::stepped end]
$g find_next
update
check "find_next unfolds the hit's region" 0 [$g folded 0]
check "on_reveal saw the region still folded" 1 [dict get [lindex $::revealed end] folded]
$g find_next
update
set before [$T2 yview]
$g find_next
update
check "on_reveal ran before the scroll" $before [dict get [lindex $::revealed end] yview]
check "on_reveal saw the far region still folded" 1 [dict get [lindex $::revealed end] folded]
check "the step scrolled" 1 [expr {[$T2 yview] ne $before}]
check "the step brought the hit into view" 1 [expr {[$T2 bbox [apple "carrot apple"]] ne ""}]
$g find_next
check "find_next reached the last hit" "5 of 5" [fv FindPos]
$g find_next
check "find_next wraps to the first hit" "1 of 5" [fv FindPos]
$g find_prev
check "find_prev wraps to the last hit" "5 of 5" [fv FindPos]
$g find_prev
check "find_prev steps back" "4 of 5" [fv FindPos]
check "a step leaves the insert mark on the hit" [apple "carrot apple"] [$T2 index insert]

fset FindNocase 0
$g find_typing
check "flipping the case box blanks the readout" "" [fv FindPos]
$g find_next
check "a case flip recollects case-sensitively" "1 of 4" [fv FindPos]
fset FindNocase 1

fset FindVar xyzzy
$g find_next
check "a term with no hits reads 0 of 0" "0 of 0" [fv FindPos]

# ---- the bar ----------------------------------------------------------------
check "the bar is unplaced until shown" "" [winfo manager .f.find]
$d find_show
update
check "find_show grids the bar by default" grid [winfo manager .f.find]
check "the default bar sits in the row below the text" 1 [dict get [grid info .f.find] -row]
$d find_hide
check "find_hide unplaces the bar" "" [winfo manager .f.find]
check "Ctrl-F on the text shows the bar" 1 [string match *find_show* [bind $T <Control-f>]]
check "Ctrl-F on the host frame shows the bar" 1 [string match *find_show* [bind .f <Control-f>]]
check "Return on the entry steps forward" 1 [string match *find_next* [bind .f.find.e <Return>]]
check "Shift-Return on the entry steps back" 1 [string match *find_prev* [bind .f.find.e <Shift-Return>]]
check "Escape on the text hides the bar" 1 [string match *find_hide* [bind $T <Escape>]]

oo::define Finder method place_find {frame} { place $frame -x 0 -y 0 -relwidth 1 }
fset FindVar apple
$g find_show
update
check "a place_find override is honoured" place [winfo manager .t2.f.find]
$g find_next
set last [$T2 index insert]
set c $::cleared
$g find_hide
check "find_hide unplaces an overridden bar" "" [winfo manager .t2.f.find]
check "find_hide clears the hits" {} [fv FindMatches]
check "find_hide clears the readout" "" [fv FindPos]
check "find_hide removes the find tag" {} [$T2 tag ranges find]
check "find_clear calls find_cleared" [expr {$c + 1}] $::cleared
check "find_hide leaves the insert mark at the last hit" $last [$T2 index insert]

check "audit gate never tripped" 0 [tripped]
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
