#!/usr/bin/env wish9.0
# The emit half of tkdown: painting parsed markdown onto a Tk text widget.
#
# Where test-tkdown-parse.tcl drives the pure parse procs under a bare tclsh,
# this drives the widget-facing procs that need Tk: the per-widget registry
# and its options, the td-* faces, the block walk and its emitters, link and
# table search, and the grid a table renders as.
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
package require -exact tkdown 2.1a2

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
check "plain text carries the base tag and td-margin" \
    [lsort [.r tag names 1.0]] {base td-margin}
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
::tkdown::prose .l4 end "intro line\n- a\n- b\n\noutro line" base ""
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
# The window indices of w's tables, in document order, and a table's payload.
proc tblidx {w} { lmap t [::tkdown::table_list $w] { lindex $t 0 } }
proc payload {w idx} { lindex [::tkdown::table_spec $w $idx] 1 }

set LONG [string repeat "word after word wraps " 14]
set WIDE "intro
| Key | Note |
| --- | :-: |
| **alpha** | short |
| beta | $LONG |
| gamma | the zanzibar token sits only in this *styled* cell |"

::tkdown::body $G end $WIDE base code
check "a table makes one window" [llength [$G dump -window 1.0 end]] 3
set T1 [lindex [$G dump -window 1.0 end] 2]
check "table_list knows it by its window's index" [tblidx $G] $T1
check "its -create script carries id, payload and base tags" \
    [lrange [::tkdown::table_spec $G $T1] 0 0] 1
check "the payload is the parsed table" [dict get [payload $G $T1] align] {left center}
check "the window character carries td-tblwin, td-margin and the base tags" \
    [lsort [$G tag names $T1]] {base td-margin td-tblwin}
check "the prose above ends its line before the table" \
    [$G get 1.0 $T1] "intro\n"
check "the window ends its line" [$G get $T1+1c] "\n"
check "nothing is built before the text shows it" [winfo exists $G.tbl1] 0
check "table_spec knows no plain character" [::tkdown::table_spec $G 1.0] ""
update; update
set f $G.tbl1
check "update realises the frame" [winfo exists $f] 1
check "the window is the frame" [lindex [$G dump -window $T1] 1] $f
check "table_spec reads a built grid by its path too" \
    [lindex [::tkdown::table_spec $G $f] 0] 1
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
foreach row [dict get [payload $G $T1] rows] {
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
::tkdown::body $N end $TBL base code
update; update
set nat [lmap m [minsizes $N.tbl1] { expr {$m - 10} }]
set natwant [list]
foreach j {0 1 2} {
    set mx 0
    set hdr 1
    foreach row [dict get [payload $N $N.tbl1] rows] {
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

# A column whose cells are all empty, header included.
set E [pane emp]
::tkdown::tags $E $FA
::tkdown::body $E end "| a |  | c |\n| --- | --- | --- |\n| x |  | z |" base code
update; update
set emp [lmap m [minsizes $E.tbl1] { expr {$m - 10} }]
# The allocator gives it nothing; the cell's own one-character request
# is what the grid spends.
check "the allocator gives the empty column no width" [lindex $emp 1] 0
check "the grid column is still one character wide" \
    [lindex [grid bbox $E.tbl1 1 0] 2] [expr {[font measure fa-body 0] + 10}]
destroy .emp
update

# ---- 8. table_scan and table_spotlight --------------------------------------
check "table_scan finds a word only a cell holds" \
    [::tkdown::table_scan $G zanzibar 1] \
    [list [list $T1 "the zanzibar token sits only in this styled cell"]]
check "table_scan honours case when asked" [::tkdown::table_scan $G ZANZIBAR 0] {}
check "table_scan folds case when asked" \
    [llength [::tkdown::table_scan $G ZANZIBAR 1]] 1
check "table_scan does not see the prose" [::tkdown::table_scan $G intro 1] {}
check "an empty needle finds nothing" [::tkdown::table_scan $G "" 1] {}
# A second table painted above the first: the hits come in document order.
$G mark set top 1.0
::tkdown::body $G top $TBL base code
lassign [tblidx $G] T2 T1
check "a later-numbered table above comes first" \
    [::tkdown::table_scan $G e 1] [list [list $T2 Name] [list $T1 Key]]
check "the first table's index moved down with the insert" \
    [lindex [$G dump -window $T1] 1] $f

::tkdown::table_spotlight $G $T1
check "the spotlight paints td-spot's colour" [$f cget -background] #ffee00
check "and holds the lit table's id" [dict get [reg $G] spot] 1
::tkdown::table_spotlight $G $T2
check "lighting another puts the first out" [$f cget -background] #aaaaaa
::tkdown::table_spotlight $G end-1c
check "an index holding no table puts the light out" [dict get [reg $G] spot] ""
::tkdown::table_spotlight $G $T2
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
    [::tkdown::table_to_markdown [payload $G $f]]
check "and acknowledges with a tick" [$f.copy cget -text] "✓"
after 800 {set ::waited 1}
vwait ::waited
check "the tick reverts after 700 ms" [$f.copy cget -text] "⧉"
event generate $G <Motion> -warp 1 -x 2 -y 2
event generate $f <Leave>
update
check "leaving the table hides its copy button" [winfo manager $f.copy] ""

# ---- 10. refit: margins and option changes ----------------------------------
set x0 [lindex [$G bbox $f] 0]
::tkdown::refit $G -margin 20
check "refit moves the window's margin" [$G tag cget td-tblwin -lmargin1] 20
update; update
check "the window moved with it" [expr {[lindex [$G bbox $f] 0] - $x0}] 20
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
::tkdown::body $FCW end $WIDE base code
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
::tkdown::body $S end $TBL base code
::tkdown::table_spotlight $S [tblidx $S]
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

# ---- 11. deleting the text, forget ------------------------------------------
::tkdown::table_spotlight $G $T1
::tkdown::forget $G
check "forget leaves the grids in the text" [winfo exists $f] 1
check "forget puts the spotlight out" \
    [list [dict get [reg $G] spot] [$f cget -background]] {{} #aaaaaa}
$G delete 1.0 end
check "a delete takes the built grids with their windows" [winfo children $G] {}
::tkdown::body $G end "$TBL\n\ntext\n\n$TBL" base code
update; update
set n1 [llength [winfo children $G]]
$G delete 1.0 end
::tkdown::body $G end "$TBL\n\ntext\n\n$TBL" base code
update; update
check "a second render makes no more children" \
    [llength [winfo children $G]] $n1
check "table ids carry on, never reused" \
    [lmap t [::tkdown::table_list $G] { lindex $t 1 }] {5 6}

# A delete above a table: the index table_scan gives is the window's still.
$G delete 1.0 end
::tkdown::body $G end "one\ntwo\nthree\n\n$TBL" base code
set at [lindex [::tkdown::table_scan $G apple 1] 0 0]
check "table_scan gives the window character's index" \
    [lindex [$G dump -window $at] 0] window
$G delete 1.0 3.0
set moved [lindex [::tkdown::table_scan $G apple 1] 0 0]
check "table_scan's index follows a delete above the table" \
    $moved [$G index "$at -2 lines"]
check "and is still the window's" [lindex [$G dump -window $moved] 0] window

# Delete without forget: one table built, one far below never shown.
$G delete 1.0 end
::tkdown::body $G end "$TBL\n\n[string repeat "filler\n" 200]\n$TBL" base code
update; update
check "only the visible table is built" \
    [list [winfo exists $G.tbl8] [winfo exists $G.tbl9]] {1 0}
check "both tables are in the text" [llength [::tkdown::table_scan $G apple 1]] 2
$G delete 1.0 end
update
check "after delete 1.0 end, table_scan finds nothing" \
    [::tkdown::table_scan $G apple 1] {}
check "and the text holds no window" [$G window names] {}
check "the built frame went with its window" [winfo exists $G.tbl8] 0
check "forget after the delete is harmless" [catch {::tkdown::forget $G}] 0
check "and leaves nothing to find" [::tkdown::table_scan $G apple 1] {}
::tkdown::refit $G
update
check "a refit over the empty pane is harmless too" [winfo children $G] {}

# A pane destroyed while it holds a built grid unregisters cleanly.
::tkdown::body $G end $TBL base code
update; update
destroy $G
update
check "destroying a pane with a grid unregisters it" \
    [dict exists [set ::tkdown::widgets] $G] 0
check "and drops its grid bindtag's bindings" [bind tkdown.grid$G] {}

# ---- 12. ensure_fonts --------------------------------------------------------
set TF [::tkdown::ensure_fonts]
check "ensure_fonts returns the Td* fonts dict" $TF \
    {body TdBody bold TdBodyBold italic TdBodyItalic bolditalic TdBodyBoldItalic mono TdMono monobold TdMonoBold}
check "every face it names exists" \
    [lmap f [dict values $TF] { expr {$f in [font names]} }] {1 1 1 1 1 1}
check "a second call creates nothing and returns the same" [::tkdown::ensure_fonts] $TF
check "TdBodyBold is TkTextFont's family in bold" \
    [list [font actual TdBodyBold -family] [font actual TdBodyBold -weight]] \
    [list [font actual TkTextFont -family] bold]
check "TdMonoBold is TkFixedFont's family in bold" \
    [list [font actual TdMonoBold -family] [font actual TdMonoBold -weight]] \
    [list [font actual TkFixedFont -family] bold]
text .tf
check "tags takes the dict, monobold and all" [catch {::tkdown::tags .tf $TF}] 0
destroy .tf

# ---- 13. the walk: blocks, their newlines and -on_block -----------------------
set ::blocks {}
proc heard {args} { lappend ::blocks $args }
text .b
::tkdown::tags .b $FA -on_block heard
::tkdown::body .b end "intro\n```\ncode line\n```\n> q1\n---\n!\[alt\](p.png)\n| a | b |\n|---|---|\n| 1 | 2 |\n\nafter" base code
check "-on_block hears every block in order" [lmap b $::blocks { lindex $b 0 }] \
    {prose code quote rule image table prose}
check "the blocks run from the start to the body's closing newline" \
    [list [lindex $::blocks 0 1] [lindex $::blocks end 2]] [list 1.0 [.b index end-2c]]
set gaps {}
foreach a [lrange $::blocks 0 end-1] b [lrange $::blocks 1 end] {
    lappend gaps [.b get [lindex $a 2] [lindex $b 1]]
}
check "only the quote's setting-off newline lies between blocks" \
    $gaps [list "" "\n" "" "" "" ""]
check "each block's range holds what it painted" \
    [lmap b $::blocks { .b get [lindex $b 1] [lindex $b 2] }] \
    [list "intro\n" "code line\n" "▏ q1\n" " \n" "alt\n" "\n" "\nafter\n"]
check "the table's range holds its window" \
    [llength [.b dump -window [lindex $::blocks 5 1] [lindex $::blocks 5 2]]] 3
check "each block hears its text" [lmap b $::blocks { lindex $b 3 }] \
    [list intro "code line" q1 "" alt "| a | b |\n| --- | --- |\n| 1 | 2 |" "\nafter"]
check "code goes in under codeTags and td-margin" \
    [lsort [.b tag names [lindex $::blocks 1 1]]] {code td-margin}
set qs [lindex $::blocks 2 1]
.b insert $qs "HOST\n"
check "an insert at a quote's start lands on the quote's first line" \
    [.b get "$qs linestart" "$qs +1l lineend"] "HOST\n▏ q1"
::tkdown::forget .b

# A table under a list starts on a line of its own.
text .lt
::tkdown::tags .lt $FA
::tkdown::body .lt end "- a\n- b\n| x | y |\n|---|---|\n| 1 | 2 |" base code
set m [tblidx .lt]
check "a list ends its line before a table" \
    [.lt get "$m -1c linestart" $m] "•\tb\n"
# The grid's own guard: a table emitted mid-line opens a line first.
.lt insert end "tail" base
::tkdown::emit_table .lt end [dict create align left rows {{h} {v}}] base
set m [lindex [tblidx .lt] end]
check "a table met mid-line starts its own line" [.lt get "$m -1c"] "\n"
::tkdown::forget .lt

# ---- 14. emitters: replaced, switched off, refused ---------------------------
proc myquote {w idx text baseTags} { $w insert $idx "Q:$text" $baseTags }
text .e
::tkdown::tags .e $FA
::tkdown::body .e end "> hi" base code [dict create quote myquote]
check "a given emitter replaces the default; the walk ends its line" \
    [.e get 1.0 end-1c] "Q:hi\n\n"
.e delete 1.0 end
::tkdown::body .e end "> **not** quoted\nnext" base code {quote ""}
check "quote \"\" leaves a > line literal" [.e get 1.0 end-1c] "> not quoted\nnext\n\n"
check "and paints no quote" [.e tag ranges td-quote] {}
check "its runs still style" [tagtext .e td-bold] not
.e delete 1.0 end
::tkdown::body .e end "a\n```\nx\n```" base code {code ""}
check "code \"\" leaves the fence lines in the prose" [.e get 1.0 end-1c] "a\n```\nx\n```\n\n"
.e delete 1.0 end
::tkdown::body .e end "a\n\n---\n\n!\[cat\](c.png)\n\n| a |\n| - |" base code \
    {rule "" image "" table ""}
check "rule, image and table \"\" reach prose as written" \
    [.e get 1.0 end-1c] "a\n\n---\n\ncat\n\n| a |\n| - |\n\n"
check "an unknown kind errors" [catch {::tkdown::body .e end x base code {bogus p}}] 1
check "an empty prose emitter errors" [catch {::tkdown::body .e end x base code {prose ""}}] 1

# ---- 15. the default quote emitter -------------------------------------------
text .q
::tkdown::tags .q $FA -quotetags {qink qinset} -margin 6
::tkdown::body .q end "intro\n> one *it*\n> > inner\nafter" base code
check "a quote after a line of prose is set off by a blank line" \
    [.q get 1.0 4.0] "intro\n\n▏ one it\n"
check "each line opens with the bar" [tagtext .q td-quotebar] "▏ ▏ "
check "a nested > stays literal" [.q get 4.0 "4.0 lineend"] "▏ > inner"
check "the block carries td-quote" [tagtext .q td-quote] "▏ one it\n▏ > inner\n"
set i [lindex [.q tag ranges td-italic] 0]
check "a quote's runs carry the base tags and -quotetags" \
    [lsort [.q tag names $i]] {base qink qinset td-italic td-margin td-quote}
check "td-quote insets from the margin" \
    [list [.q tag cget td-quote -lmargin1] [.q tag cget td-quote -lmargin2]] {20 20}
.q delete 1.0 end
::tkdown::body .q end "intro\n\n> q" base code
check "a blank line already there is not doubled" [.q get 1.0 4.0] "intro\n\n▏ q\n"
.q delete 1.0 end
::tkdown::body .q end "> q\n\n---\n\nA" base code
check "a blank line between two blocks is kept" [.q get 1.0 end-1c] "▏ q\n\n \n\nA\n\n"

# ---- 16. rules, setext headings, images ---------------------------------------
text .x
::tkdown::tags .x $FA
::tkdown::body .x end "para\n\n---\n\nmore" base code
check "a rule is one line of a space under td-rule" [tagtext .x td-rule] " \n"
check "and the base tags and td-margin" \
    [lsort [.x tag names [lindex [.x tag ranges td-rule] 0]]] {base td-margin td-rule}
check "td-rule's face is TdRule, two pixels" \
    [list [.x tag cget td-rule -font] [font configure TdRule -size]] {TdRule -2}
# A base tag spacing its lines, created after tags, cannot widen the rule.
.x tag configure spaced -spacing1 4 -spacing3 6
.x delete 1.0 end
::tkdown::body .x end "para\n\n---\n\nmore" spaced code
pack .x
update
set ri [lindex [.x tag ranges td-rule] 0]
check "a rule's line is the rule face's height under a spaced base tag" \
    [expr {abs([lindex [.x dlineinfo $ri] 3] \
        - [font metrics TdRule -linespace]) <= 1}] 1
pack forget .x
.x delete 1.0 end
::tkdown::body .x end "Title\n---\nbody\n\nBig\n===" base code
check "a line over --- paints as h2" [tagtext .x td-h2] Title
check "a line over === paints as h1" [tagtext .x td-h1] Big
check "and is not a rule" [.x tag ranges td-rule] {}
check "the underline is gone" [.x get 1.0 end-1c] "Title\nbody\n\nBig\n\n"
.x delete 1.0 end
::tkdown::body .x end "## Closed ##" base code
check "an ATX heading drops its closing hashes" [tagtext .x td-h2] Closed

.x delete 1.0 end
::tkdown::body .x end "!\[a *cat*\](cat.png)" base code
check "with no -image_cmd an image paints its alt text" [.x get 1.0 end-1c] "a cat\n\n"
check "its runs style" [tagtext .x td-italic] cat
image create photo dot -width 4 -height 4
set ::asked {}
proc img_for {path} { lappend ::asked $path; expr {$path eq "dot.png" ? "dot" : ""} }
::tkdown::refit .x -image_cmd img_for
.x delete 1.0 end
::tkdown::body .x end "!\[d\](dot.png)\n!\[gone\](none.png)" base code
check "-image_cmd is asked for each path" $::asked {dot.png none.png}
check "an image it returns is embedded" [lindex [.x dump -image 1.0 end] 1] dot
check "under the base tags and td-margin" [lsort [.x tag names 1.0]] {base td-margin}
check "an empty answer falls back to the alt" [.x get 2.0 "2.0 lineend"] gone

# ---- 17. links -----------------------------------------------------------------
text .k
::tkdown::tags .k $FA
.k tag configure td-link -underline 1
::tkdown::runs .k end {see [docs](https://x.org/D) and https://y.org/e.} base
check "a link's text lies under td-link" [tagtext .k td-link] "docshttps://y.org/e"
check "td-link carries the body face" [.k tag cget td-link -font] [dict get $FA body]
set d [lindex [.k tag ranges td-link] 0]
check "a link's characters carry base, td-link, its own tag and td-margin" \
    [regexp {^base td-link td-link\d+ td-margin$} [lsort [.k tag names $d]]] 1
check "link_at gives the url under an index" [::tkdown::link_at .k "$d +2c"] https://x.org/D
check "and nothing off a link" [::tkdown::link_at .k 1.0] ""
check "link_scan finds by url, a url its text also shows left out" \
    [::tkdown::link_scan .k org 0] [list [list $d https://x.org/D]]
::tkdown::runs .k end { [w](https://w.org/z)} base
check "link_scan gives its hits in document order" \
    [lmap h [::tkdown::link_scan .k .org/ 0] { lindex $h 1 }] {https://x.org/D https://w.org/z}
check "a needle in a link's text is not link_scan's" \
    [::tkdown::link_scan .k docs 1] {}
check "nor is a bare url, its text being its url" [::tkdown::link_scan .k y.org 1] {}
check "link_scan honours case when asked" [::tkdown::link_scan .k x.org/d 0] {}
check "link_scan folds case when asked" [llength [::tkdown::link_scan .k X.ORG/D 1]] 1
check "an empty needle finds nothing" [::tkdown::link_scan .k "" 1] {}
set before [lsort [lsearch -all -inline -regexp [.k tag names] {^td-link\d+$}]]
::tkdown::forget .k
check "forget deletes the per-link tags" \
    [lsearch -all -inline -regexp [.k tag names] {^td-link\d+$}] {}
check "and link_at knows nothing" [::tkdown::link_at .k "$d +2c"] ""
::tkdown::runs .k end { [again](u)} base
set after [lsearch -all -inline -regexp [.k tag names] {^td-link\d+$}]
check "a link's number is never reused" [expr {$after ni $before}] 1
.k delete 1.0 end
check "link_scan drops a link whose text is gone" \
    [list [::tkdown::link_scan .k u 0] [dict get [reg .k] links]] {{} {}}

# ---- 18. nested lists ------------------------------------------------------------
text .n
::tkdown::tags .n $FA
::tkdown::body .n end "- a\n  - b\n        - c\n1. d" base code
check "nested items keep their markers" [.n get 1.0 5.0] "•\ta\n•\tb\n•\tc\n1.\td\n"
check "each item carries its depth tag" \
    [lmap ln {1 2 3 4} { lsearch -inline -regexp [.n tag names $ln.0] {^td-list\d+$} }] \
    {td-list0 td-list1 td-list2 td-list0}
check "a depth jump clamps to one below the parent" \
    [expr {"td-list3" in [.n tag names]}] 0
check "each depth indents 18 px more, its text 20 px past the marker" \
    [lmap t {td-list0 td-list1 td-list2} {
        list [.n tag cget $t -lmargin1] [.n tag cget $t -lmargin2]
    }] {{10 30} {28 48} {46 66}}
::tkdown::refit .n -margin 5
check "refit moves every depth with the margin" \
    [list [.n tag cget td-list2 -lmargin1] [.n tag cget td-list2 -tabs]] {51 71}
check "a nested item's text still styles" \
    [catch {::tkdown::body .n end "- x\n  - **y**" base code}] 0
check "inside it" [tagtext .n td-bold] y

# A continued item keeps its line break, the continuation at the item text.
text .lc -width 40
::tkdown::tags .lc $FA -margin 6
pack .lc
::tkdown::body .lc end "- first line\nlazy line\n  - sub\n    indented line" base code
update
check "a continuation keeps its line break" [.lc get 1.0 5.0] \
    "•\tfirst line\nlazy line\n•\tsub\nindented line\n"
check "a continued line starts at the item text's x" \
    [expr {[lindex [.lc bbox 2.0] 0] == [lindex [.lc bbox 1.2] 0]}] 1
check "and a nested one at its own item's" \
    [expr {[lindex [.lc bbox 4.0] 0] == [lindex [.lc bbox 3.2] 0]}] 1
check "the continued line is still the item's" \
    [lsearch -inline -regexp [.lc tag names 4.0] {^td-list\d+$}] td-list1
pack forget .lc

# ---- 19. td-margin --------------------------------------------------------------
# A host tag with a margin of its own, configured before tags is called.
text .m
.m tag configure early -lmargin1 77
::tkdown::tags .m $FA -margin {24 30}
check "td-margin exists from tags on" \
    [list [.m tag cget td-margin -lmargin1] [.m tag cget td-margin -rmargin]] {24 30}
::tkdown::body .m end "para\n\n- item\n\n> q" base code
proc marginof {w idx opt} {
    foreach tag [lreverse [$w tag names $idx]] {
        set v [$w tag cget $tag $opt]
        if {$v ne ""} { return $v }
    }
    return 0
}
check "a prose line carries td-margin" [expr {"td-margin" in [.m tag names 1.0]}] 1
check "a prose line's margins are -margin's" \
    [list [marginof .m 1.0 -lmargin1] [marginof .m 1.0 -rmargin]] {24 30}
set li [lindex [.m tag ranges td-list] 0]
check "a list line carries td-margin" [expr {"td-margin" in [.m tag names $li]}] 1
check "a list line's lmargin1 is the list indent, past the margin" \
    [marginof .m $li -lmargin1] [.m tag cget td-list0 -lmargin1]
check "which is more than the margin" [expr {[marginof .m $li -lmargin1] > 24}] 1
set qi [lindex [.m tag ranges td-quote] 0]
check "a quote line's inset wins over td-margin" [marginof .m $qi -lmargin1] 38
::tkdown::refit .m -margin 60
check "refit moves a prose line's margins" \
    [list [marginof .m 1.0 -lmargin1] [marginof .m 1.0 -rmargin]] {60 60}
check "td-margin stays lowest after refit" [lindex [.m tag names] 0] td-margin
.m tag configure late -lmargin1 99
.m delete 1.0 end
::tkdown::runs .m end "x" {base early}
::tkdown::runs .m end "\ny" {base late}
check "a host tag created before tags wins over td-margin" [marginof .m 1.0 -lmargin1] 77
check "and so does one created after" [marginof .m 2.0 -lmargin1] 99

# ---- 20. -on_block skips the blank line between blocks ------------------------
set ::blocks {}
text .ob
::tkdown::tags .ob $FA -on_block heard
::tkdown::body .ob end "> q\n\n---" base code
check "a quote, blank line, rule reports quote and rule" \
    [lmap b $::blocks { lindex $b 0 }] {quote rule}
check "the blank line is still painted" [.ob get 1.0 end-1c] "▏ q\n\n \n\n"

# ---- 21. links in cells, and -link_cmd ----------------------------------------
set ::opened {}
proc opened {url} { lappend ::opened $url }
# A press, an optional drag to (dx,dy), and a release, on text widget t at
# the character idx, the pointer first moved there so the text sees the tag.
proc click {t idx {dx 0} {dy 0}} {
    lassign [$t bbox $idx] x y bw bh
    set x [expr {$x + $bw / 2}]
    set y [expr {$y + $bh / 2}]
    event generate $t <Motion> -x $x -y $y
    event generate $t <ButtonPress-1> -x $x -y $y
    if {$dx || $dy} {
        event generate $t <B1-Motion> -x [expr {$x + $dx}] -y [expr {$y + $dy}]
    }
    event generate $t <ButtonRelease-1> -x [expr {$x + $dx}] -y [expr {$y + $dy}]
    update
}
set L [pane lnk]
::tkdown::tags $L $FA -link_cmd opened
$L tag configure td-link -foreground #0000ff -underline 1
::tkdown::body $L end "see \[docs\](https://x.org/D) here and more text\n\n| \[Head\](https://h.org/k) | b |\n| --- | --- |\n| \[site\](https://cell.org/x) | plain |" base code
update; update
set d [lindex [$L tag ranges td-link] 0]
click $L "$d +1c"
check "a click on a link calls -link_cmd with its url, once" $::opened https://x.org/D
set ::opened {}
click $L "$d +1c" 200 40
check "a press on a link dragged off and released elsewhere opens nothing" $::opened {}
check "the drag made a selection" [expr {[$L tag ranges sel] ne ""}] 1
$L tag remove sel 1.0 end
click $L "$d +1c" 6 0
check "a drag of more than 4 px along the link opens nothing" $::opened {}
click $L 1.0
check "a click off a link opens nothing" $::opened {}
event generate $L <Motion> -x 0 -y 0
lassign [$L bbox "$d +1c"] x y
event generate $L <Motion> -x [expr {$x + 2}] -y [expr {$y + 2}]
update
check "the pointer over a link shows the hand" [$L cget -cursor] hand2
event generate $L <Motion> -x [lindex [$L bbox 1.0] 0] -y [lindex [$L bbox 1.0] 1]
update
check "and leaving it gives the widget its own cursor back" [$L cget -cursor] xterm

set tf $L.tbl1
$L see [tblidx $L]
update; update
check "the grid is built" [winfo exists $tf] 1
set hc $tf.c0x0
set bc $tf.c1x0
check "a cell link paints its text" [$bc get 1.0 end-1c] site
check "under the cell's link tags" [lsort [$bc tag names 1.0]] {lk lnk1}
check "a cell link takes td-link's ink" \
    [list [$bc tag cget lk -foreground] [$bc tag cget lk -underline]] [list #0000ff 1]
check "a header-row cell link stays bold" \
    [expr {"hb" in [$hc tag names 1.0] && "lk" in [$hc tag names 1.0]
        && [lsearch [$hc tag names 1.0] hb] > [lsearch [$hc tag names 1.0] lk]}] 1
click $bc 1.1
check "a click on a cell link calls -link_cmd with its url" $::opened https://cell.org/x
set ::opened {}
click $bc 1.1 0 60
check "a cell press dragged off opens nothing" $::opened {}
$L tag configure td-link -foreground #00aa00
::tkdown::refit $L
update
check "refit re-inks a cell link from td-link" [$bc tag cget lk -foreground] #00aa00
check "link_scan finds a cell link by its url, at the table's window" \
    [::tkdown::link_scan $L cell.org 1] [list [list [tblidx $L] https://cell.org/x]]
check "link_scan merges the body's and the cells' links in document order" \
    [lmap h [::tkdown::link_scan $L .org/ 1] { lindex $h 1 }] \
    {https://x.org/D https://h.org/k https://cell.org/x}
check "a cell link's shown text is not link_scan's" [::tkdown::link_scan $L site 1] {}

::tkdown::refit $L -link_cmd {}
check "without -link_cmd tkdown takes its bindings off td-link" \
    [lmap ev {<ButtonPress-1> <ButtonRelease-1> <Enter> <Leave>} { $L tag bind td-link $ev }] \
    {{} {} {} {}}
click $bc 1.1
check "and a cell link has ink but no click" $::opened {}
$L tag bind td-link <ButtonRelease-1> {lappend ::opened host}
::tkdown::refit $L
check "a host's own td-link binding survives a refit without -link_cmd" \
    [$L tag bind td-link <ButtonRelease-1>] {lappend ::opened host}
destroy .lnk

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
