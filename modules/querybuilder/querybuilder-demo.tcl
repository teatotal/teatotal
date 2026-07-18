#!/usr/bin/env wish9.0
# A standalone demo of the QueryBuilder widget: a bar of structured criteria
# kept as chips, filtering a tea shelf. The facets arrive as descriptor dicts -
# two chip lists with combobox editors, one bespoke control reporting through
# report_values, and an optional facet revealed from the add rail - and the
# bar's change callback refilters the shelf. It loads only the querybuilder
# module; what a criterion means is this script's business, not the widget's.
#
# Run it with bare wish:   wish9.0 modules/querybuilder/querybuilder-demo.tcl
#
# Try: press a "+ or" to add another value; delete a chip with its ×; set
# Strength (a control facet: it draws no chips while expanded); press "+ tag"
# on the rail to reveal the optional facet; collapse the bar with ▾ - every
# criterion stays visible as a chip, delete affordance live.

package require Tcl 9
package require Tk

set HERE [file dirname [file normalize [info script]]]
foreach md [glob -directory [file dirname $HERE] -type d *] { ::tcl::tm::path add $md }
package require querybuilder

# ---- the shelf: what the criteria are FOR is the consumer's business --------

set TEAS {
    {name "Dragonwell"        type green  origin China  strength light  tags {classic}}
    {name "Sencha"            type green  origin Japan  strength light  tags {classic daily}}
    {name "Gyokuro"           type green  origin Japan  strength medium tags {shaded}}
    {name "Assam Breakfast"   type black  origin India  strength strong tags {daily milk}}
    {name "Darjeeling First"  type black  origin India  strength medium tags {muscatel}}
    {name "Keemun"            type black  origin China  strength medium tags {smoky}}
    {name "Tie Guan Yin"      type oolong origin China  strength medium tags {classic floral}}
    {name "Dong Ding"         type oolong origin Taiwan strength medium tags {roasted}}
    {name "Oriental Beauty"   type oolong origin Taiwan strength light  tags {honeyed}}
    {name "Silver Needle"     type white  origin China  strength light  tags {buds}}
    {name "Aged Shou Puer"    type puer   origin China  strength strong tags {earthy daily}}
    {name "Lapsang Souchong"  type black  origin China  strength strong tags {smoky}}
}

# ---- the editors: the type-specific part, hung on the facets as data --------

# A chips-mode editor builds only the control the "+" affordance opens into.
# The builder hands an empty frame, the criterion under edit (empty on a fresh
# add), and the two exits; Escape needs no code here, the builder binds it.
proc pick_editor {choices frame initial commit cancel} {
    ttk::combobox $frame.v -values $choices -width 10
    if {[dict size $initial]} { $frame.v set [dict get $initial value] }
    pack $frame.v -side left
    bind $frame.v <Return> [list apply {{f c} { {*}$c [$f.v get] }} $frame $commit]
    bind $frame.v <<ComboboxSelected>> \
        [list apply {{f c} { {*}$c [$f.v get] }} $frame $commit]
    focus $frame.v
}

# A control-mode editor owns the whole editor area and is redrawn from the
# model every time its row is drawn, so it reads the values door for its
# current state. It reports through report_values - the door that leaves the
# reporter's own widgets alone - and, this being the host's control, the host
# publishes; "any" reports no value at all, so at rest the facet holds nothing
# and the collapsed bar draws no chip for it.
proc strength_editor {frame initial commit cancel} {
    set cur [lindex [$::bar values strength] 0]
    ttk::combobox $frame.v -state readonly -width 8 \
        -values {any light medium strong}
    $frame.v set [expr {$cur eq "" ? "any" : $cur}]
    pack $frame.v -side left
    bind $frame.v <<ComboboxSelected>> {
        set v [%W get]
        $::bar report_values strength [expr {$v eq "any" ? {} : [list $v]}]
        $::bar publish
    }
}

# ---- the bar ----------------------------------------------------------------

set bar [::querybuilder::QueryBuilder new]
$bar configure -heading "Show the teas that" -countfmt "%d active" \
    -changecommand {refilter} -facets [list \
    [list kind type label type conn "are" orword "or" \
        editor {pick_editor {green black oolong white puer}}] \
    [list kind origin label origin conn "come from" orword "or" \
        editor {pick_editor {China Japan India Taiwan}}] \
    [list kind strength label strength conn "brew" mode control max 1 \
        editor strength_editor] \
    [list kind tag label tag conn "carry the tag" orword "and" ortext "+ and" \
        tail 1 editor {pick_editor {classic daily smoky roasted floral}}]]

pack [ttk::frame .bar -padding 8] -fill x
$bar setup .bar

# ---- the answer path: merge nothing, just filter the shelf ------------------

# A tea passes when every applied facet accepts it: within a facet the values
# are alternatives (the bar draws "or" between those chips), except tags,
# whose chips join with "and" and must all be carried - the connector words
# say what this proc does.
proc keep {tea m} {
    foreach kind {type origin strength} {
        set want [dict get $m $kind]
        if {[llength $want] && [dict get $tea $kind] ni $want} { return 0 }
    }
    foreach t [dict get $m tag] {
        if {$t ni [dict get $tea tags]} { return 0 }
    }
    return 1
}

proc refilter {args} {
    set m [$::bar model]
    .shelf configure -state normal
    .shelf delete 1.0 end
    set n 0
    foreach tea $::TEAS {
        if {![keep $tea $m]} continue
        incr n
        .shelf insert end [format "%-19s" [dict get $tea name]] name
        .shelf insert end [format "  %-7s %-7s %-7s" [dict get $tea type] \
            [dict get $tea origin] [dict get $tea strength]] meta
        .shelf insert end "  [join [dict get $tea tags] {, }]\n" meta
    }
    .shelf configure -state disabled
    .status configure -text "$n of [llength $::TEAS] teas · [$::bar fragment]"
}

text .shelf -font TkFixedFont -height 13 -width 62 -borderwidth 0 -padx 10 -pady 6
.shelf tag configure name -font TkHeadingFont
.shelf tag configure meta -foreground #5a6b78
ttk::label .status -anchor w -padding {8 3} -foreground #52606d
pack .status -side bottom -fill x
pack .shelf -fill both -expand 1

# Seed two criteria. Programmatic doors are quiet, so the seeds cost nothing;
# one call to the answer path draws the first shelf.
$bar add_criterion type oolong
$bar add_criterion origin China
refilter

wm title . "querybuilder demo"
