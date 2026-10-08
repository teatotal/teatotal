#!/usr/bin/env wish9.0
# A standalone demo of the tkdown renderer: one reading pane painting a
# markdown sampler that exercises every form the module covers - ATX headings,
# emphasis and code spans, a fenced block, a blockquote (split off with
# segment_blockquotes and painted by the host, the idiom the man page
# describes), GFM tables - one with mixed alignment and styled cells, one too
# wide for the pane - and bullet and numbered flat lists. It loads only the
# tkdown module.
#
# Run it with bare wish:   wish9.0 modules/tkdown/tkdown-demo.tcl
#
# Try: narrow the window and the wide table's long cells wrap to keep it
# inside the pane; the font-size spinbox re-sizes the registered fonts and
# calls ::tkdown::refit, so every grid re-fits its columns to the new face.

package require Tcl 9
package require Tk

set HERE [file dirname [file normalize [info script]]]
foreach md [glob -directory [file dirname $HERE] -type d *] { ::tcl::tm::path add $md }
package require tkdown 2.0a1

# The host owns the fonts: tkdown binds its faces onto names the host has
# already created and sized, which is what lets one spinbox re-size the lot.
set ::fontsize 11
foreach {name base extra} {
    DemoBody   TkTextFont  {}
    DemoBold   TkTextFont  {-weight bold}
    DemoItalic TkTextFont  {-slant italic}
    DemoBI     TkTextFont  {-weight bold -slant italic}
    DemoMono   TkFixedFont {}
    DemoH1     TkTextFont  {-weight bold}
    DemoH2     TkTextFont  {-weight bold}
    DemoH3     TkTextFont  {-weight bold -slant italic}
} {
    font create $name {*}[font actual $base] {*}$extra
}
proc size_fonts {} {
    set s $::fontsize
    foreach {name delta} {DemoBody 0 DemoBold 0 DemoItalic 0 DemoBI 0
                          DemoMono -1 DemoH1 6 DemoH2 3 DemoH3 1} {
        font configure $name -size [expr {$s + $delta}]
    }
}
size_fonts

set SAMPLER {# tkdown sampler

This pane is one Tk `text` widget painted by tkdown. Inline runs carry
*italic*, **bold**, ***both***, and `code spans`; asterisks used as math,
3 * 4, and names like snake_case stay literal.

## A fenced block

```tcl
proc greet {who} {
    puts "hello, $who"      ;# markers inside a fence stay raw: **not bold**
}
```

## A blockquote

> The emit walk never paints quotes itself: the host splits them off with
> segment_blockquotes and paints each de-quoted run under its own chrome,
> the bar and indent you see on this paragraph.

## A GFM table

| Form | Marker | Where it *lands* |
|:-----|:------:|-----------------:|
| heading | `#` through `######` | clamped to **h3** |
| table | pipes | a grid of wrapping cells |
| list | `-` or `1.` | one row per item |

A table wider than the pane keeps its columns and wraps its longest cells, each column given the width that costs the fewest wrapped lines:

| Module | Role | Notes |
|:-------|:-----|:------|
| tkdown | markdown onto a text widget | Paints prose, fenced code, lists and pipe tables; every `td-*` tag it configures is a face or a margin, so the host keeps the ink. |
| streamdoc | a reading pane | Holds the text widget, its scrolling and its find bar, and knows nothing of markdown; a host joins the two with a line or two of glue. |
| a host | the application | Owns the fonts, the colours and the margins, and decides when a document is painted, forgotten and painted again. |

### Lists

- a bullet item with **bold** inside
- a second bullet
- a third, with a `code span`

1. numbered items keep their source numbering
2. so a list can start anywhere
7. even at seven}

# ---- window ----------------------------------------------------------------
pack [ttk::frame .bar] -side top -fill x
ttk::label .bar.t -text "tkdown demo - a markdown sampler"
pack .bar.t -side left -padx 6 -pady 4
ttk::label .bar.szl -text "font size"
ttk::spinbox .bar.sz -from 7 -to 24 -width 3 -textvariable ::fontsize \
    -command {size_fonts; ::tkdown::refit .body.t}
pack .bar.sz .bar.szl -side right -padx 4

pack [ttk::frame .body] -fill both -expand 1
text .body.t -wrap word -padx 14 -pady 10 -borderwidth 0 -font DemoBody \
    -yscrollcommand {.body.sb set}
ttk::scrollbar .body.sb -command {.body.t yview}
pack .body.sb -side right -fill y
pack .body.t -side left -fill both -expand 1

::tkdown::tags .body.t [dict create \
    body DemoBody bold DemoBold italic DemoItalic bolditalic DemoBI \
    mono DemoMono h1 DemoH1 h2 DemoH2 h3 DemoH3]

# Host chrome: the module's td-* tags are font or geometry only, so ink and
# the quote bar are ordinary tags the host configures and stacks underneath.
.body.t tag configure base -foreground #102a43
.body.t tag configure fence -font DemoMono -background #eef2f6 \
    -lmargin1 18 -lmargin2 18 -rmargin 18 -spacing1 4 -spacing3 4
.body.t tag configure quote -foreground #52606d \
    -lmargin1 22 -lmargin2 22 -rmargin 22
# A grid's gridlines are the host's ink too.
.body.t tag configure td-grid -background #c8d1dc

# Paint the sampler through the layered splitters, fences first so a marker
# inside a fence never reads as a quote, then quotes, prose through ::prose
# (which handles headings, tables and lists itself). A code segment inserts
# verbatim under host tags, the codeTags role ::tkdown::body gives the host.
foreach seg [::tkdown::segment_code_fences $SAMPLER] {
    lassign $seg kind text
    if {$kind eq "code"} {
        .body.t insert end "$text\n" {base fence}
        .body.t insert end "\n" base
        continue
    }
    foreach qseg [::tkdown::segment_blockquotes $text] {
        lassign $qseg qkind qtext
        set tags [expr {$qkind eq "quote" ? {base quote} : {base}}]
        ::tkdown::prose .body.t end $qtext $tags
    }
}
.body.t configure -state disabled

wm title . "tkdown demo"
