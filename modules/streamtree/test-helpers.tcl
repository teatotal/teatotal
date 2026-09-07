#!/usr/bin/env wish9.0
# The subclass helpers a hook body reaches for: `sort` says what the active
# sort is, sort_by_payload and sort_by_value order a host's own key lists
# under it, and truncate_px never hands back more than the budget it was
# given, an ellipsis included.

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file dirname [file normalize [info script]]]]]
foreach md [glob -directory [file join $ROOT modules] -type d *] { ::tcl::tm::path add $md }
package require streamtree

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name\n  expected: $expected\n  actual:   $actual"
        incr ::fails
    } else { puts "ok:   $name" }
}

# One sortable numeric column and a subject that sorts by label.
oo::class create Sized {
    superclass ::streamtree::StreamTree
    constructor {parent} { my setup $parent }
    method column_spec {} { return {{size Size 9999 right 1}} }
    method subject_sort_id {} { return name }
    method default_sort_dir {id} { return [expr {$id eq "name" ? "asc" : "desc"}] }
    method sort_key {payload col} {
        return [expr {$col eq "size" ? [dict getdef $payload size 0] : [dict getdef $payload label ""]}]
    }
}
pack [ttk::frame .f] -fill both -expand 1
set d [Sized new .f]

# --- The accessor follows set_sort: a fresh tree sorts by its subject key in
#     that key's default direction, a column click adopts the column in its
#     own, a second click flips it.
check "a fresh tree sorts by the subject key" {name asc} [$d sort]
$d set_sort size
check "adopting a column starts it in its default direction" {size desc} [$d sort]
$d set_sort size
check "adopting it again flips the direction" {size asc} [$d sort]

# --- sort_by_payload reads each key's value through sort_key; a key with no
#     payload sorts as -1, first ascending.
set payloads [dict create a {size 30} b {size 10} c {size 20}]
check "keys ordered by their payloads under the active sort" {b c a} \
    [$d sort_by_payload {a b c} $payloads]
check "a key with no payload sorts as -1" {x b c a} [$d sort_by_payload {a x b c} $payloads]
$d set_sort size
check "and the other way round when the direction flips" {a c b x} \
    [$d sort_by_payload {a x b c} $payloads]

# --- sort_by_value reads a key->value map, numeric by default, as strings on
#     request; an absent key takes the comparator's zero.
check "values compared as numbers" {p q r} [$d sort_by_value {q r p} {p 3 q 2 r 1}]
check "an absent key sorts as 0.0" {p q r z} [$d sort_by_value {q r p z} {p 3 q 2 r 1}]
$d set_sort size
check "strings compared as a dictionary, ascending" {a2 a10 b} \
    [$d sort_by_value {b a10 a2} {b b a10 a10 a2 a2} -dictionary]
check "an absent key sorts as the empty string" {z a2 a10 b} \
    [$d sort_by_value {b z a10 a2} {b b a10 a10 a2 a2} -dictionary]

# --- truncate_px: what fits comes back whole; what does not is cut to an
#     ellipsis within the budget; a budget the ellipsis itself overruns gets
#     nothing, not a glyph wider than the room.
set font TkTextFont
set text "a plausible label that runs on for a while"
set wide [font measure $font $text]
check "text within the budget is untouched" $text [$d truncate_px $text $wide $font]
set cut [$d truncate_px $text [expr {$wide / 2}] $font]
check "a cut text ends in an ellipsis" "…" [string index $cut end]
check "and fits the budget" 1 [expr {[font measure $font $cut] <= $wide / 2}]
set ell [font measure $font "…"]
check "a budget narrower than the ellipsis gets nothing" "" [$d truncate_px $text [expr {$ell - 1}] $font]
check "a budget of exactly the ellipsis gets it" "…" [$d truncate_px $text $ell $font]
check "a short text narrower than the ellipsis still fits its own budget" "i" [$d truncate_px "i" [font measure $font "i"] $font]
check "no budget, nothing" "" [$d truncate_px $text 0 $font]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
