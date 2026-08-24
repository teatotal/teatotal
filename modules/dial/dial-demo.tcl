#!/usr/bin/env wish9.0
# A standalone demo of the dial module: a countdown whose wedge sweeps away
# rather than a bar that shrinks. Three dials run different windows against
# one clock, and the rightmost is ringed to show the selection mark. When a
# dial's count expires it takes the `held` face, and Start hands it a fresh
# window. It loads only the dial module.
#
# Run it with bare wish:   wish9.0 modules/dial/dial-demo.tcl
#
# Try: watch a disc go fully dark at the start of its window and fully lit at
# the end - the shape says which way the count runs without reading the number.

package require Tcl 9
package require Tk

set HERE [file dirname [file normalize [info script]]]
foreach md [glob -directory [file dirname $HERE] -type d *] { ::tcl::tm::path add $md }
package require dial

# One dial: a label, the photo it is holding, and the window it counts down.
array set LEFT {}
array set WINDOW {}
array set PHOTO {}
proc start {name window} {
    set ::WINDOW($name) $window
    set ::LEFT($name) $window
}
proc paint {name ring} {
    set p [expr {$::LEFT($name) / double($::WINDOW($name))}]
    if {$::LEFT($name) > 0} {
        set state cooling
        set caption "OPENS IN\n[expr {int(ceil($::LEFT($name) / 1000.0))}]"
    } else {
        set state held
        set caption "READY"
    }
    set ::PHOTO($name) [dial::show .deck.$name $::PHOTO($name) \
        $p $state $caption 96 $ring]
}
proc tick {} {
    foreach {name ring} {short "" medium "" long "#f5c542"} {
        if {$::LEFT($name) > 0} { incr ::LEFT($name) -120 }
        paint $name $ring
    }
    after 120 tick
}

pack [ttk::frame .bar] -side top -fill x
ttk::label .bar.t -text "dial demo - a countdown that cannot be read backwards"
pack .bar.t -side left -padx 6 -pady 4
ttk::button .bar.go -text Start -command {
    start short 6000 ; start medium 15000 ; start long 30000
}
pack .bar.go -side right -padx 6 -pady 4

pack [ttk::frame .deck -padding 12] -fill both -expand 1
foreach {name window} {short 6000 medium 15000 long 30000} {
    ttk::label .deck.$name
    pack .deck.$name -side left -padx 14
    set PHOTO($name) ""
    start $name $window
}
tick

wm title . "dial demo"
