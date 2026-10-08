#!/usr/bin/env wish9.0
# The emit half of tkdown: painting parsed markdown onto a Tk text widget.
#
# Where test-tkdown-parse.tcl drives the pure parse procs under a bare tclsh,
# this drives the widget-facing procs - tags, runs, prose, body, refit,
# forget, table_scan, table_spotlight - that need Tk: the per-widget
# registry and its options, the td-* faces, and the grid a table renders as.
# It requires only tkdown and builds its own named fonts, so a pass proves
# the module stands alone.
#
# Runs under wish (it builds and maps widgets):
#   timeout 120 xvfb-run -a wish9.0 test-tkdown-emit.tcl

# A background error would otherwise sit in a dialog and hold the run open.
proc bgerror {m} { puts "BGERROR: $m"; exit 2 }

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file dirname [file normalize [info script]]]]]
foreach md [glob -directory [file join $ROOT modules] -type d *] { ::tcl::tm::path add $md }
package prefer latest
package require tkdown

set fails 0
proc check {name got want} {
    if {$got eq $want} {
        puts "ok   - $name"
    } else {
        puts "FAIL - $name"
        puts "       got:  $got"
        puts "       want: $want"
        incr ::fails
    }
}

# A named-font set the fonts dict needs, one Tk font per required key plus the
# optional headings left out (so the h1-h3 fallback is exercised).
proc mkfonts {prefix size} {
    font create ${prefix}body       -family Courier -size $size
    font create ${prefix}bold       -family Courier -size $size -weight bold
    font create ${prefix}italic     -family Courier -size $size -slant italic
    font create ${prefix}bolditalic -family Courier -size $size -weight bold -slant italic
    font create ${prefix}mono       -family Courier -size $size
    return [dict create body ${prefix}body bold ${prefix}bold \
        italic ${prefix}italic bolditalic ${prefix}bolditalic \
        mono ${prefix}mono]
}
set FA [mkfonts fa- 10]   ;# default set
set FC [mkfonts fc- 10]   ;# an isolated set the font-change test mutates

# Concatenated text of every range a tag covers.
proc tagtext {w tag} {
    set s ""
    foreach {a b} [$w tag ranges $tag] { append s [$w get $a $b] }
    return $s
}
proc reg {w} { return [dict get [set ::tkdown::widgets] $w] }

set TBL "| Name | Qty | Price |
| :--- | --: | --: |
| apple | 3 | 100 |
| fig | 12 | 5 |"

# ---- 1. tags: validation and the heading fallback ---------------------------
text .v
check "missing a required font key errors" \
    [catch {::tkdown::tags .v [dict remove $FA mono]} e] 1
check "the error names the missing key" [string match {*"mono"*} $e] 1
::tkdown::tags .v $FA
check "h1 falls back to bold when unset" \
    [.v tag cget td-h1 -font] [dict get $FA bold]
check "h2 falls back to bold when unset" \
    [.v tag cget td-h2 -font] [dict get $FA bold]
check "h3 falls back to bold when unset" \
    [.v tag cget td-h3 -font] [dict get $FA bold]

# ---- 2. runs: inline spans carry the right td-* over the right chars ---------
text .r
::tkdown::tags .r $FA
::tkdown::runs .r end "hello **world** and `code` here" base
check "td-bold covers exactly the emphasised word" [tagtext .r td-bold] "world"
check "td-code covers exactly the code span" [tagtext .r td-code] "code"
check "plain text carries only the base tag" [.r tag names 1.0] "base"
check "an emphasis span still stacks the base tag" \
    [expr {"base" in [.r tag names [lindex [.r tag ranges td-bold] 0]]}] 1
# Italic / bolditalic on their own faces.
::tkdown::runs .r end "an *aside* and ***both***" base
check "td-italic covers the italic word" [tagtext .r td-italic] "aside"
check "td-bolditalic covers the bolditalic word" [tagtext .r td-bolditalic] "both"

# ---- 3. prose: headings -----------------------------------------------------
text .h
::tkdown::tags .h $FA
::tkdown::prose .h end "# Alpha\n## Beta\n#### Delta" base ""
check "an ATX # line lands under td-h1" [tagtext .h td-h1] "Alpha"
check "an ATX ## line lands under td-h2" [tagtext .h td-h2] "Beta"
check "an ATX #### line clamps to td-h3" [tagtext .h td-h3] "Delta"

# A non-heading paragraph renders byte-for-byte the same whether or not a
# heading precedes it in the run.
text .p1
text .p2
::tkdown::tags .p1 $FA
::tkdown::tags .p2 $FA
::tkdown::prose .p1 end "alpha beta\ngamma delta" base ""
::tkdown::prose .p2 end "# A Heading\nalpha beta\ngamma delta" base ""
set para [.p1 get 1.0 "end-1c"]
set tail [string range [.p2 get 1.0 "end-1c"] [string length "A Heading\n"] end]
check "the plain paragraph renders identically with a heading above it" $tail $para

# ---- 4. options: parsing, defaults, margins ----------------------------------
text .o
::tkdown::tags .o $FA
check "-margin defaults to {0 0}" [dict get [reg .o] margin] {0 0}
check "-copystyle defaults to Copy.TButton" [dict get [reg .o] copystyle] Copy.TButton
check "td-tblwin sits at the margin" [.o tag cget td-tblwin -lmargin1] 0
::tkdown::tags .o $FA -margin 12 -quotetags {q ink} -image_cmd img -on_block blk
check "one -margin distance serves both sides" [dict get [reg .o] margin] {12 12}
check "-quotetags is stored" [dict get [reg .o] quotetags] {q ink}
check "-image_cmd is stored" [dict get [reg .o] image_cmd] img
check "-on_block is stored" [dict get [reg .o] on_block] blk
check "td-list's hanging indent is offset from the margin" \
    [list [.o tag cget td-list -lmargin1] [.o tag cget td-list -lmargin2]] {22 42}
check "td-tblwin follows the margin" \
    [list [.o tag cget td-tblwin -lmargin1] [.o tag cget td-tblwin -rmargin]] {12 12}
check "an unknown option errors" [catch {::tkdown::tags .o $FA -bogus 1}] 1
check "an option without a value errors" [catch {::tkdown::refit .o -margin}] 1

# ---- 5. destroying a registered widget, then re-registering the path --------
text .g
::tkdown::tags .g $FA
destroy .g   ;# <Destroy> unregisters it
text .g
check "tags on a fresh widget of the same path succeeds" \
    [catch {::tkdown::tags .g $FA}] 0
check "the re-registered widget configures its faces" \
    [.g tag cget td-bold -font] [dict get $FA bold]

# ---- 6. lists: td-list ranges, hanging indent, ordered numbering -------------
text .l
::tkdown::tags .l $FA
check "td-list has lmargin1 shallower than lmargin2 (hanging indent)" \
    [expr {[.l tag cget td-list -lmargin1] < [.l tag cget td-list -lmargin2]}] 1
check "the td-list tab stop matches lmargin2" \
    [expr {[lindex [.l tag cget td-list -tabs] 0] == [.l tag cget td-list -lmargin2]}] 1

::tkdown::prose .l end "- apples\n- pears" base ""
check "an unordered list renders under td-list" \
    [expr {[llength [.l tag ranges td-list]] > 0}] 1
check "each bullet item carries the • marker then its text" \
    [tagtext .l td-list] "•\tapples\n•\tpears"
check "plain bullet text stacks the base tag under td-list" \
    [expr {"base" in [.l tag names [lindex [.l tag ranges td-list] 0]]}] 1

text .l2
::tkdown::tags .l2 $FA
::tkdown::prose .l2 end "3. gamma\n4. delta" base ""
check "an ordered list preserves its own numbers and dots" \
    [tagtext .l2 td-list] "3.\tgamma\n4.\tdelta"

# Inline markdown inside an item still styles through the run path.
text .l3
::tkdown::tags .l3 $FA
::tkdown::prose .l3 end "- see **bold** now" base ""
check "emphasis inside a list item still styles" [tagtext .l3 td-bold] "bold"

# Prose above and below a list; the list band is its own td-list range.
text .l4
::tkdown::tags .l4 $FA
::tkdown::prose .l4 end "intro line\n- a\n- b\noutro line" base ""
check "prose around a list stays outside td-list" [tagtext .l4 td-list] "•\ta\n•\tb"
check "the surrounding prose is present in the widget" \
    [expr {[string match {*intro line*outro line*} [.l4 get 1.0 end-1c]]}] 1

# A marker-like line that is not a flat list marker stays literal (no td-list).
text .l5
::tkdown::tags .l5 $FA
::tkdown::prose .l5 end "compute 3 * 4 then done" base ""
check "marker-like mid-line text carries no td-list" \
    [expr {[llength [.l5 tag ranges td-list]]}] 0

# ---- 7. the grid: a table is one embedded window ----------------------------
# A mapped pane of a known size in a toplevel of its own, so windows
# realise and fits have a width.
proc pane {name args} {
    toplevel .$name
    frame .$name.f -width 600 -height 400
    pack propagate .$name.f 0
    pack .$name.f
    text .$name.f.t -wrap word {*}$args
    pack .$name.f.t -fill both -expand 1
    return .$name.f.t
}
set G [pane grid -padx 6 -borderwidth 1]
::tkdown::tags $G $FA
$G tag configure base -foreground #123456
$G tag configure td-grid -background #aaaaaa
$G tag configure td-spot -background #ffee00

# The pane's inner width less the margins: what the fit may spend.
proc inner {w} {
    expr {[winfo width $w] - 2 * ([$w cget -borderwidth] \
        + [$w cget -highlightthickness] + [$w cget -padx])}
}
proc minsizes {f} {
    lmap j [lrange [lsearch -all [lrepeat 32 x] x] 0 [lindex [grid size $f] 0]-1] {
        grid columnconfigure $f $j -minsize
    }
}
proc tblmarks {w} { lsort [lsearch -all -inline -glob [$w mark names] tbl#m*] }

set LONG [string repeat "word after word wraps " 14]
set WIDE "intro
| Key | Note |
| --- | :-: |
| **alpha** | short |
| beta | $LONG |
| gamma | the zanzibar token sits only in this *styled* cell |"

::tkdown::prose $G end $WIDE base ""
check "a table makes one window" [llength [$G dump -window 1.0 end]] 3
check "and one mark" [tblmarks $G] tbl#m1
check "the window character carries td-tblwin and the base tags" \
    [lsort [$G tag names tbl#m1]] {base td-tblwin}
check "the mark sits on the window character" \
    [lindex [$G dump -window tbl#m1] 0] window
check "a table met mid-line starts its own line" [$G get tbl#m1-1c] "\n"
check "the window is followed by a blank line" [$G get tbl#m1+1c tbl#m1+3c] "\n\n"
check "nothing is built before the text shows it" [winfo exists $G.tbl1] 0
update; update
set f $G.tbl1
check "update realises the frame" [winfo exists $f] 1
check "the window is the frame" [lindex [$G dump -window tbl#m1] 1] $f
check "a cell holds its text with the inline markers dropped" \
    [$f.c1x0 get 1.0 end-1c] alpha
check "a styled cell reads as the reader sees it" [$f.c3x1 get 1.0 end-1c] \
    "the zanzibar token sits only in this styled cell"
check "a header cell is bold throughout" \
    [expr {"hb" in [$f.c0x1 tag names 1.0]}] 1
check "a centred column justifies its cells" [$f.c2x1 tag cget al -justify] center
check "cells are read-only" [$f.c1x0 cget -state] disabled
check "the frame shows the td-grid colour" [$f cget -background] #aaaaaa
check "cell ink comes from the first base tag with a foreground" \
    [$f.c1x0 cget -foreground] #123456
check "cell background is the pane's" [$f.c1x0 cget -background] [$G cget -background]

# The fit: table_colwidths over the measured words, pinned as minsizes.
set rows [list]
set hdr 1
foreach row [dict get [dict get [reg $G] tables] 1 payload rows] {
    lappend rows [lmap c $row { ::tkdown::cell_tokens $FA $c $hdr }]
    set hdr 0
}
check "a word is measured in its run's face" \
    [lindex $rows 1 0] [list [font measure fa-bold alpha]]
check "a header word is measured bold" \
    [lindex $rows 0 0] [list [font measure fa-bold Key]]
set avail [expr {[inner $G] - 2 * 10}]
set want [::tkdown::table_colwidths $rows $avail \
    [font measure fa-body 0] [font measure fa-body " "]]
set got [lmap m [minsizes $f] { expr {$m - 10} }]
check "the column widths are table_colwidths' over the pane" $got $want
check "the columns spend at most the pane" \
    [expr {[tcl::mathop::+ {*}$got] <= $avail}] 1
check "a long cell wraps" [expr {[$f.c2x1 cget -height] > 1}] 1
check "its height is its display-line count" [$f.c2x1 cget -height] \
    [$f.c2x1 count -displaylines 1.0 end]
check "the table fits the pane" [expr {[winfo width $f] <= [inner $G]}] 1

# A table that fits keeps its natural widths and does not stretch.
set N [pane nat]
::tkdown::tags $N $FA
::tkdown::prose $N end $TBL base ""
update; update
set nat [lmap m [minsizes $N.tbl1] { expr {$m - 10} }]
set natwant [list]
foreach j {0 1 2} {
    set mx 0
    set hdr 1
    foreach row [dict get [dict get [reg $N] tables] 1 payload rows] {
        set px [tcl::mathop::+ 0 {*}[::tkdown::cell_tokens $FA [lindex $row $j] $hdr]]
        if {$px > $mx} { set mx $px }
        set hdr 0
    }
    lappend natwant $mx
}
check "a table that fits gets its natural widths" $nat $natwant
check "and is narrower than the pane" \
    [expr {[winfo width $N.tbl1] < [inner $N]}] 1
destroy .nat
update

# ---- 8. table_scan and table_spotlight --------------------------------------
check "table_scan finds a word only a cell holds" \
    [::tkdown::table_scan $G zanzibar 1] \
    [list [list tbl#m1 "the zanzibar token sits only in this styled cell"]]
check "table_scan honours case when asked" [::tkdown::table_scan $G ZANZIBAR 0] {}
check "table_scan folds case when asked" \
    [llength [::tkdown::table_scan $G ZANZIBAR 1]] 1
check "table_scan does not see the prose" [::tkdown::table_scan $G intro 1] {}
check "an empty needle finds nothing" [::tkdown::table_scan $G "" 1] {}
# A second table painted above the first: the hits come in document order.
$G mark set top 1.0
::tkdown::prose $G top $TBL base "\n"
check "a later-numbered table above comes first" \
    [::tkdown::table_scan $G e 1] [list {tbl#m2 Name} {tbl#m1 Key}]

::tkdown::table_spotlight $G tbl#m1
check "the spotlight paints td-spot's colour" [$f cget -background] #ffee00
::tkdown::table_spotlight $G tbl#m2
check "lighting another puts the first out" [$f cget -background] #aaaaaa
::tkdown::table_spotlight $G ""
check "an empty index puts the light out" [dict get [reg $G] spot] ""
update
check "the second table is out too" [$G.tbl2 cget -background] #aaaaaa

# ---- 9. wheel and copy ------------------------------------------------------
set ::wheel {}
bind $G <MouseWheel> {lappend ::wheel %D}
bind $G <Shift-MouseWheel> {lappend ::wheel shift %D}
event generate $f.c2x1 <MouseWheel> -delta -240
event generate $f.c2x1 <Shift-MouseWheel> -delta 120
event generate $f <MouseWheel> -delta 360
check "the wheel over a cell or the frame reaches the pane, delta intact" \
    $::wheel {-240 shift 120 360}
bind $G <MouseWheel> {}
bind $G <Shift-MouseWheel> {}

event generate $f.c1x0 <Enter>
check "entering the table shows its copy button" [winfo manager $f.copy] place
$f.copy invoke
check "the button copies the table as GFM" [clipboard get] \
    [::tkdown::table_to_markdown [dict get [dict get [reg $G] tables] 1 payload]]
check "and acknowledges with a tick" [$f.copy cget -text] "✓"
after 800 {set ::waited 1}
vwait ::waited
check "the tick reverts after 700 ms" [$f.copy cget -text] "⧉"
event generate $G <Motion> -warp 1 -x 2 -y 2
event generate $f <Leave>
update
check "leaving the table hides its copy button" [winfo manager $f.copy] ""

# ---- 10. refit: margins and option changes ----------------------------------
set x0 [lindex [$G bbox tbl#m1] 0]
::tkdown::refit $G -margin 20
check "refit moves the window's margin" [$G tag cget td-tblwin -lmargin1] 20
update; update
check "the window moved with it" [expr {[lindex [$G bbox tbl#m1] 0] - $x0}] 20
set avail20 [expr {[inner $G] - 40 - 2 * 10}]
set want20 [::tkdown::table_colwidths $rows $avail20 \
    [font measure fa-body 0] [font measure fa-body " "]]
check "refit re-fits to the narrower room" \
    [lmap m [minsizes $f] { expr {$m - 10} }] $want20
::tkdown::refit $G -margin {0 0}
update; update

# A reading-font change re-fits through refit, words measured afresh.
set FCW [pane fc]
::tkdown::tags $FCW $FC
::tkdown::prose $FCW end $WIDE base ""
update; update
set before [minsizes $FCW.tbl1]
font configure fc-body -size 16
font configure fc-bold -size 16
::tkdown::refit $FCW
update; update
check "a font change re-fits the columns" \
    [expr {[minsizes $FCW.tbl1] ne $before}] 1
check "and the grid still fits the pane" \
    [expr {[winfo width $FCW.tbl1] <= [inner $FCW]}] 1
destroy .fc

# An unknown -copystyle still builds, on plain TButton; a table spotlit
# before it is ever shown is built lit.
toplevel .s
frame .s.f -width 600 -height 400
pack propagate .s.f 0
pack .s.f
set S [text .s.f.t]
::tkdown::tags $S $FA -copystyle NoSuchStyle
$S tag configure td-spot -background #00ff00
::tkdown::prose $S end $TBL base ""
::tkdown::table_spotlight $S tbl#m1
pack $S -fill both -expand 1
update; update
check "an unknown -copystyle still realises" [winfo exists $S.tbl1] 1
check "its button falls back to TButton" [$S.tbl1.copy cget -style] TButton
check "a grid spotlit before it was built is born lit" \
    [$S.tbl1 cget -background] #00ff00
check "with no td-grid, the gridlines take the pane's foreground" \
    [::tkdown::grid_colour $S] [$S cget -foreground]
::tkdown::refit $S -copystyle TButton
check "refit restyles a built button" [$S.tbl1.copy cget -style] TButton
destroy .s
update
check "destroying the pane unregisters it" \
    [dict exists [set ::tkdown::widgets] $S] 0

# ---- 11. forget, and a delete without it ------------------------------------
::tkdown::forget $G
check "forget leaves w no children" [winfo children $G] {}
check "forget unsets every table mark" [tblmarks $G] {}
check "forget empties the registry's tables" [dict get [reg $G] tables] {}
$G delete 1.0 end
::tkdown::body $G end "$TBL\n\ntext\n\n$TBL" base code
update; update
set n1 [llength [winfo children $G]]
::tkdown::forget $G
$G delete 1.0 end
::tkdown::body $G end "$TBL\n\ntext\n\n$TBL" base code
update; update
check "a second render after forget makes no more children" \
    [llength [winfo children $G]] $n1
check "table ids restart after forget" [tblmarks $G] {tbl#m1 tbl#m2}
::tkdown::forget $G
check "and forget clears them again" [winfo children $G] {}

# Delete without forget: one table built, one far below never shown.
$G delete 1.0 end
::tkdown::prose $G end "$TBL\n\n[string repeat "filler\n" 200]\n$TBL" base ""
update; update
check "only the visible table is built" \
    [list [winfo exists $G.tbl1] [winfo exists $G.tbl2]] {1 0}
$G delete 1.0 end
update
check "table_scan finds nothing once the text is gone" \
    [::tkdown::table_scan $G apple 1] {}
check "and the registry is empty" [dict get [reg $G] tables] {}
check "the built frame went with its window" [winfo exists $G.tbl1] 0
::tkdown::forget $G

# A pane destroyed while it holds a built grid unregisters cleanly.
::tkdown::prose $G end $TBL base ""
update; update
destroy $G
update
check "destroying a pane with a grid unregisters it" \
    [dict exists [set ::tkdown::widgets] $G] 0
check "and drops its grid bindtag's bindings" [bind tkdown.grid$G] {}

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
