#!/usr/bin/env wish9.0
# A standalone demo of the SearchField widget, wired to a QueryBuilder the way
# the query contract intends: two widgets, neither knowing the other, each
# publishing a fragment, and this script - the consumer - merging the two
# dicts into one query it answers over a tea shelf. The field brings the typed
# half (debounced live terms, quoted phrases, the case toggle, the region
# picker); the builder brings the structured half; promotion turns a typed
# "origin:china" into a criterion chip, and a collapsed builder mirrors its
# criteria as removable pills inside the field.
#
# Run it with bare wish:   wish9.0 modules/searchfield/searchfield-demo.tcl
#
# Try: type a word and pause - the debounce publishes and the shelf refilters;
# quote a phrase ("silver needle" is one term); flip Aa or pick a region; type
# origin:japan followed by a space - the token leaves the field and lands as a
# chip below; collapse the builder with ▾ - its criteria appear as pills in
# the field, and a pill's × removes the criterion itself.

package require Tcl 9
package require Tk

set HERE [file dirname [file normalize [info script]]]
foreach md [glob -directory [file dirname $HERE] -type d *] { ::tcl::tm::path add $md }
package require searchfield
package require querybuilder

# ---- the shelf: the corpus the merged query is answered over ----------------

set TEAS {
    {name "Dragonwell"        type green  origin China
     notes "flat jade leaves, chestnut sweetness"}
    {name "Sencha"            type green  origin Japan
     notes "grassy, bright, the daily cup"}
    {name "Gyokuro"           type green  origin Japan
     notes "shaded leaf, deep umami broth"}
    {name "Assam Breakfast"   type black  origin India
     notes "malty and brisk, stands up to milk"}
    {name "Darjeeling First"  type black  origin India
     notes "muscatel spring flush, light amber"}
    {name "Keemun"            type black  origin China
     notes "wisp of smoke over cocoa"}
    {name "Tie Guan Yin"      type oolong origin China
     notes "orchid nose, rolled emerald leaf"}
    {name "Dong Ding"         type oolong origin Taiwan
     notes "charcoal roast, buttery finish"}
    {name "Oriental Beauty"   type oolong origin Taiwan
     notes "leafhopper-bitten, honeyed dusk"}
    {name "Silver Needle"     type white  origin China
     notes "downy buds, meadow and melon"}
    {name "Aged Shou Puer"    type puer   origin China
     notes "earthy cellar depth, dark liquor"}
}

# ---- the two widgets: neither names the other -------------------------------

set sf [::searchfield::SearchField new]
set qb [::querybuilder::QueryBuilder new]

proc pick_editor {choices frame initial commit cancel} {
    ttk::combobox $frame.v -values $choices -width 10
    if {[dict size $initial]} { $frame.v set [dict get $initial value] }
    pack $frame.v -side left
    bind $frame.v <Return> [list apply {{f c} { {*}$c [$f.v get] }} $frame $commit]
    bind $frame.v <<ComboboxSelected>> \
        [list apply {{f c} { {*}$c [$f.v get] }} $frame $commit]
    focus $frame.v
}

$qb configure -heading "and that" -changecommand {on_query_change} \
    -foldcommand {sync_tokens} -facets {
        {kind origin label origin conn "come from"
         editor {pick_editor {China Japan India Taiwan}}}
        {kind type   label type   conn "are"
         editor {pick_editor {green black oolong white puer}}}
    }

# The promote pattern is built from the builder's declaration, so a facet
# added to -facets above promotes with no change below. A term matching it is
# withheld from every publish: nobody scans the shelf for a half-typed
# "origin:c".
$sf configure -label "Find:" -inlabel "in" \
    -placeholder "try: buds, \"silver needle\", origin:china" \
    -regions {any "any part" name "the name" notes "the notes"} \
    -live 1 -debounce 250 \
    -changecommand {on_query_change} \
    -removecommand {on_token_removed} \
    -promotepattern "^([join [$qb kinds] |]):(.+)\$" \
    -promoteon tokenend \
    -promotecommand {promote}

# The field calls here with the term and the pattern's own capture groups.
# Returning "" consumes it: the text leaves the field, the criterion lands in
# the builder, and the one publish that follows carries both fragments.
proc promote {term submatches} {
    lassign $submatches kind value
    $::qb add_criterion $kind [string totitle $value]
    return ""
}

# ---- the consumer's whole linkage: mirror, merge, answer --------------------

# While the builder is collapsed, its criteria ride inside the field as
# pills: the criterion's stable id is the pill's tag, the builder's own
# format renders the label, so pill and chip read identically. Expanded, the
# builder shows them itself and the field goes bare. Setting an unchanged
# token list is a no-op by contract, so re-mirroring on every publish is free.
proc sync_tokens {args} {
    if {[$::qb collapsed]} {
        $::sf tokens [lmap c [dict get [$::qb fragment] criteria] {
            list label [$::qb format $c] tag [dict get $c id]
        }]
    } else {
        $::sf tokens {}
    }
}

# A pill's × was clicked. Quiet mutators leave the consumer in charge of the
# aftermath: drop the criterion, then one pass through the common path.
proc on_token_removed {tag} {
    $::qb remove_criterion $tag
    on_query_change
}

# Both widgets call here with their own fragment; both are re-read, so one
# handler serves both and ordering cannot matter. The merge is the whole glue.
proc on_query_change {args} {
    sync_tokens
    answer [dict merge [$::sf fragment] [$::qb fragment]]
}

proc haystack {tea region} {
    switch $region {
        name    { return [dict get $tea name] }
        notes   { return [dict get $tea notes] }
        default { return "[dict get $tea name] [dict get $tea notes]" }
    }
}

proc keep {tea q} {
    set hay [haystack $tea [dict get $q region]]
    if {![dict get $q case]} { set hay [string tolower $hay] }
    foreach t [dict get $q terms] {
        if {![dict get $q case]} { set t [string tolower $t] }
        if {[string first $t $hay] < 0} { return 0 }
    }
    # Within a facet the values are alternatives - the bar draws "or" between
    # its chips, and this loop is what that word promises - while distinct
    # facets must all hold.
    set want [dict create]
    foreach c [dict get $q criteria] {
        dict lappend want [dict get $c kind] [string tolower [dict get $c value]]
    }
    dict for {kind vals} $want {
        if {[string tolower [dict get $tea $kind]] ni $vals} { return 0 }
    }
    return 1
}

proc answer {q} {
    .shelf configure -state normal
    .shelf delete 1.0 end
    set n 0
    foreach tea $::TEAS {
        if {![keep $tea $q]} continue
        incr n
        .shelf insert end [format "%-19s" [dict get $tea name]] name
        .shelf insert end [format " %-7s %-7s" [dict get $tea type] \
            [dict get $tea origin]] meta
        .shelf insert end "  [dict get $tea notes]\n" meta
    }
    .shelf configure -state disabled
    .status configure -text "$n of [llength $::TEAS] teas · $q"
}

# ---- layout: the consumer stacks the two frames it owns ---------------------

pack [ttk::frame .top -padding 8] -fill x
ttk::frame .top.sf
$sf setup .top.sf
pack .top.sf -fill x
ttk::frame .top.qb
$qb setup .top.qb
pack .top.qb -fill x -pady {8 0}

text .shelf -font TkFixedFont -height 12 -width 66 -borderwidth 0 -padx 10 -pady 6
.shelf tag configure name -font TkHeadingFont
.shelf tag configure meta -foreground #5a6b78
ttk::label .status -anchor w -padding {8 3} -foreground #52606d
pack .status -side bottom -fill x
pack .shelf -fill both -expand 1

# Seed one criterion and answer once. Programmatic doors are quiet, so the
# seed costs nothing; the first pass through the common path draws the shelf.
$qb add_criterion origin China
on_query_change

wm title . "searchfield demo"
