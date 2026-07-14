#!/usr/bin/env wish9.0
# A standalone demo of the leash mixin: deferred work that cannot outlive its
# owner. Each card is a TclOO object arming a repeating [my later] timer that
# increments its counter; the mixin's destructor cancels whatever is pending,
# so destroying a card stops its counter cold while the others keep counting,
# with no dead-command callback and no error. It loads only the leash module.
#
# Run it with bare wish:   wish9.0 demos/leash-demo.tcl
#
# Try: press a card's Destroy while its counter runs - the timer it armed dies
# with it. New deals another card.

package require Tcl 9
package require Tk

set HERE [file dirname [file normalize [info script]]]
::tcl::tm::path add [file dirname $HERE]
package require leash

font create CardCount {*}[font actual TkTextFont] -size 22 -weight bold

# A card owns a frame, a counter, and the repeating timer that drives it. The
# timer is armed only through the leash verb, so the object's destruction is
# the whole cancellation story: no flag, no guard at the call site.
oo::class create Card {
    mixin leash
    variable Frame Count

    constructor {parent name} {
        set Count 0
        set Frame [ttk::labelframe $parent.$name -text $name -padding 8]
        ttk::label $Frame.n -font CardCount -text 0 -anchor center
        ttk::button $Frame.kill -text Destroy -command [list [self] destroy]
        pack $Frame.n -fill x -pady {0 6}
        pack $Frame.kill
        pack $Frame -side left -padx 8 -pady 8 -fill y
        my tick
    }

    method tick {} {
        $Frame.n configure -text [incr Count]
        my later 300 [list [self] tick]
    }

    destructor { destroy $Frame }
}

pack [ttk::frame .bar] -side top -fill x
ttk::label .bar.t -text "leash demo - a timer dies with its owner"
pack .bar.t -side left -padx 6 -pady 4
set ::cardn 0
ttk::button .bar.new -text New -command {Card new .deck card[incr ::cardn]}
pack .bar.new -side right -padx 6 -pady 4

pack [ttk::frame .deck] -fill both -expand 1
Card new .deck card[incr ::cardn]
Card new .deck card[incr ::cardn]
Card new .deck card[incr ::cardn]

wm title . "leash demo"
