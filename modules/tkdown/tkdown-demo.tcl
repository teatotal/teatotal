#!/usr/bin/env wish9.0
# A standalone demo of the tkdown renderer: one reading pane painting a
# markdown sampler through ::tkdown::body that exercises every form the
# module covers - ATX and setext headings, emphasis, code spans and links, a
# fenced block, a blockquote, a thematic break, GFM tables - one with mixed
# alignment and styled cells, one too wide for the pane - and bullet and
# numbered lists, one nested. It loads only the tkdown module.
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
package require -exact tkdown 2.0a3

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
*italic*, **bold**, ***both***, `code spans` and links, both
[named ones](https://www.tcl-lang.org) and bare ones such as
https://wiki.tcl-lang.org; asterisks used as math, 3 * 4, and names like
snake_case stay literal. Click a link to see its url in the title bar.

## A fenced block

```tcl
proc greet {who} {
    puts "hello, $who"      ;# markers inside a fence stay raw: **not bold**
}
```

## A blockquote

> A quote gets a bar on every line and the inset of td-quote; its ink is
> the host's, laid through -quotetags. Inline *emphasis* still styles.
> > A second marker inside a quote stays literal.

---

A setext heading
----------------

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
- a second bullet, with items under it
  - a nested item
    - and one nested deeper, long enough to wrap so the hanging indent
      shows its continuation lining up with the text above
  - back one level
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

# Host chrome: the module's td-* faces and margins carry no colour, so the
# host supplies ink: base tags stacked underneath, and the td-* tags it
# colours itself.
.body.t tag configure base -foreground #102a43
.body.t tag configure fence -font DemoMono -background #eef2f6 \
    -lmargin1 18 -lmargin2 18 -rmargin 18 -spacing1 4 -spacing3 4
.body.t tag configure quote -foreground #52606d
.body.t tag configure td-quotebar -foreground #9fb3c8
.body.t tag configure td-link -foreground #0b69a3 -underline 1
.body.t tag configure td-rule -background #c8d1dc
# A grid's gridlines are the host's ink too.
.body.t tag configure td-grid -background #c8d1dc
::tkdown::refit .body.t -quotetags quote
.body.t tag bind td-link <Enter> {.body.t configure -cursor hand2}
.body.t tag bind td-link <Leave> {.body.t configure -cursor xterm}
.body.t tag bind td-link <Button-1> {
    wm title . "tkdown demo - [::tkdown::link_at .body.t @%x,%y]"
}

# One call paints the lot with the default emitters; fenced code goes in
# under the host's own tags.
::tkdown::body .body.t end $SAMPLER base {base fence}
.body.t configure -state disabled

wm title . "tkdown demo"
