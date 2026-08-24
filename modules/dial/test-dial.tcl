#!/usr/bin/env wish9.0
# Tests for the dial module: that a disc renders at every state and size the
# module claims, that the wedge and the ring change what is drawn, that an
# unknown state falls back rather than erroring, and that `show` hands the
# label the new photo before retiring the old one. The counts here are
# invented for the tests; the module knows nothing of any program that uses it.
package require Tcl 9
package require Tk
set ROOT [file dirname [file dirname [file dirname [file normalize [info script]]]]]
foreach md [glob -directory [file join $ROOT modules] -type d *] { ::tcl::tm::path add $md }
package require dial

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name"
        puts "  expected: <$expected>"
        puts "  actual:   <$actual>"
        incr ::fails
    } else {
        puts "ok:   $name"
    }
}
# The pixels of a rendered dial, as one string, so two renders can be compared.
proc pixels {im} { return [$im data] }

# -- every stock state draws, at the size asked for --------------------------

foreach st {cooling held busy} {
    set im [dial::photo 0.5 $st 60]
    check "$st draws 60px wide" 60 [image width $im]
    # Square to within the rasteriser's rounding: -scaletowidth fixes the
    # width and derives the height, which lands a pixel over on some sizes.
    check "$st draws square"     1 [expr {abs([image height $im] - 60) <= 1}]
    image delete $im
}
set im [dial::photo 0.5 cooling 24]
check "the disc rasterises to the size asked for" 24 [image width $im]
image delete $im

# -- the wedge is what the fraction moves ------------------------------------

set full [dial::photo 1.0 cooling 40]
set half [dial::photo 0.5 cooling 40]
set none [dial::photo 0.0 cooling 40]
check "a full count and a spent one differ" 0 [string equal [pixels $full] [pixels $none]]
check "half way is neither"                 0 \
    [expr {[string equal [pixels $half] [pixels $full]]
        || [string equal [pixels $half] [pixels $none]]}]
# Out of range is clamped, not an error and not a stray wedge.
check "over 1.0 clamps to a full wedge"  1 [string equal [pixels [set o [dial::photo 4.2 cooling 40]]] [pixels $full]]
check "under 0.0 clamps to none"         1 [string equal [pixels [set u [dial::photo -3.0 cooling 40]]] [pixels $none]]
foreach i [list $full $half $none $o $u] { image delete $i }

# -- states with no wedge ignore the fraction --------------------------------

foreach st {held busy} {
    set a [dial::photo 1.0 $st 40]
    set b [dial::photo 0.0 $st 40]
    check "$st draws the same at either end" 1 [string equal [pixels $a] [pixels $b]]
    image delete $a; image delete $b
}

# -- the ring is drawn outside the face, and only when asked -----------------

set plain [dial::photo 0.5 cooling 40]
set ringed [dial::photo 0.5 cooling 40 "#f5c542"]
check "a ring changes the disc"    0 [string equal [pixels $plain] [pixels $ringed]]
check "an empty ring is no ring"   1 [string equal [pixels $plain] [pixels [set e [dial::photo 0.5 cooling 40 ""]]]]
foreach i [list $plain $ringed $e] { image delete $i }

# -- an unknown state falls back rather than erroring ------------------------

set known [dial::photo 0.5 cooling 40]
set guess [dial::photo 0.5 nosuchstate 40]
check "an unknown state draws the cooling face" 1 [string equal [pixels $known] [pixels $guess]]
check "and its ink is the cooling ink" [dial::ink cooling] [dial::ink nosuchstate]
image delete $known; image delete $guess

# -- a face can be replaced by a caller with its own palette -----------------

set before [dial::photo 0.5 busy 40]
dial::face busy {#ff0000 #aa0000 #550000} "#ffffff"
set after [dial::photo 0.5 busy 40]
check "a replaced face draws differently" 0 [string equal [pixels $before] [pixels $after]]
check "and its ink follows"        "#ffffff" [dial::ink busy]
image delete $before; image delete $after
# A face named for the first time is a new state, not an error.
dial::face pause {#101010 #202020 #303030} "#c0c0c0"
check "a new face is a new state" "#c0c0c0" [dial::ink pause]
set p [dial::photo 0.5 pause 40]
check "and it draws" 40 [image width $p]
image delete $p

# -- show points the label at the new photo and retires the old one ----------

set lbl [ttk::label .d]
set first [dial::show $lbl "" 1.0 cooling "10" 48]
check "the label is holding the new photo" $first [$lbl cget -image]
check "and the caption is centred over it" center [$lbl cget -compound]
check "in the state's ink" [dial::ink cooling] [$lbl cget -foreground]
set second [dial::show $lbl $first 0.5 cooling "5" 48]
check "the label moved to the second photo" $second [$lbl cget -image]
check "and the first one is gone" 0 [expr {$first in [image names]}]
check "the caption followed" 5 [$lbl cget -text]
# A photo the caller already deleted must not take the next draw down with it.
image delete $second
set third [dial::show $lbl $second 0.25 held "0" 48]
check "retiring an already-dead photo is survivable" $third [$lbl cget -image]
image delete $third

if {$fails} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
