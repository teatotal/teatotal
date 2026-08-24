package require Tcl 9
package provide dial 1.0

# dial - a countdown drawn as a disc with a wedge that sweeps away.
#
# The MOBA/RPG ability idiom. A dark wedge covers the time still to run and
# sweeps clockwise, so the disc is fully dark the moment the count starts and
# fully lit as it reaches zero. A shrinking bar still reads as a filling bar;
# a wedge that clears cannot be read backwards, and the number in the middle
# settles it either way.
#
# Everything outside the disc is transparent, so the photo composites onto
# whatever background the containing widget has, under any ttk theme.
#
# Text is not in the SVG. nanosvg, the renderer behind Tk's svg photo format,
# parses <text> and draws nothing, so the caption rides on the widget as
# `-text ... -compound center` over the image.
#
# Tk-free at load: the module defines procedures and nothing else, so it can
# be required into an interpreter that has no Tk and may never draw. Every
# procedure that renders needs Tk, and `dial::photo` needs the svg photo
# format Tk 9 carries natively - no image files, no external renderer.
#
# A render costs about 0.2 ms including the photo delete, so a dial re-renders
# from scratch on every tick rather than caching angles. Callers own the
# photo's lifetime: pass the previous one back in and it is deleted once the
# widget is holding the new one.

namespace eval dial {
    # Design-space geometry. The photo is rasterised to whatever pixel width
    # the caller asks for, so these are ratios in disguise, not screen sizes.
    variable W 88
    variable CX 44.0
    variable CY 44.0
    variable R 39.0

    # Face gradients per state, and the caption colour that goes with each.
    # `cooling` is a count running down and is the only state with a wedge;
    # `held` is a count that has run out with nothing yet acting on it; `busy`
    # is the thing the dial counts for, under way. Each face is mid-toned
    # enough to sit on a white background and light enough to sit on a
    # near-black one, which is the constraint that picked them. No green:
    # green reads as go, and none of these states is one to act on.
    variable faces {
        cooling {#6f9ab8 #47708f #31536b}
        held    {#a8adb4 #7b8189 #5a6066}
        busy    {#f0cf7a #c79a2e #8a6a15}
    }
    variable inks {cooling #eef4fa held #1b1f24 busy #2a1f05}
}

# Define or replace a face: its three gradient stops (outer highlight, mid,
# rim) and the ink its caption is drawn in. A caller with its own palette
# names the states it wants and leaves the rest at the stock colours above.
proc dial::face {state gradient ink} {
    variable faces; variable inks
    dict set faces $state $gradient
    dict set inks $state $ink
}

# The colour for a state's centred text, so a caller styling the label does
# not have to know the palette.
proc dial::ink {state} {
    variable inks
    if {![dict exists $inks $state]} { set state cooling }
    return [dict get $inks $state]
}

# Build the dial photo. `p` is the fraction of the count still to run, 1.0 at
# the moment it starts and 0.0 when it expires; it is ignored for states with
# no wedge. `size` is the rasterised width in pixels.
#
# `ring` draws a selection ring outside the rims, empty for none. Its geometry
# belongs here, with the rest of the disc's, so it scales with the face at any
# text scale, while its colour arrives from the caller: whether this dial is
# the selected one is a fact only the caller holds, and the ring sits outside
# the disc, so a colour handed in cannot reach the face's legibility.
proc dial::photo {p state size {ring ""}} {
    variable W; variable CX; variable CY; variable R; variable faces

    if {![dict exists $faces $state]} { set state cooling }
    lassign [dict get $faces $state] hi mid lo
    if {$p < 0.0} { set p 0.0 } elseif {$p > 1.0} { set p 1.0 }

    set b "<defs><radialGradient id='f' gradientUnits='userSpaceOnUse'"
    append b " cx='30' cy='26' r='58'>"
    append b "<stop offset='0%' stop-color='$hi'/>"
    append b "<stop offset='60%' stop-color='$mid'/>"
    append b "<stop offset='100%' stop-color='$lo'/></radialGradient></defs>"

    # Two rims, because one cannot serve both backgrounds: the pale outer ring
    # separates the disc from a dark background, the dark inner ring from a
    # light one. Each is invisible against the background it is not for.
    append b "<circle cx='$CX' cy='$CY' r='[expr {$R + 2}]' fill='none'"
    append b " stroke='#9bb3c6' stroke-width='1.6' opacity='0.55'/>"
    append b "<circle cx='$CX' cy='$CY' r='$R' fill='url(#f)'"
    append b " stroke='#24323d' stroke-width='2'/>"

    if {$state eq "cooling" && $p > 0.0005} {
        append b [Wedge $p]
    }

    # Last, so nothing draws over it. Two strokes, not one: the busy face is
    # amber, and a gold ring laid straight onto gold reads as a slightly
    # fatter disc rather than as a selection. The dark stroke inside it is the
    # separation that makes the ring a ring. Its outer edge lands at 42.9 in a
    # box half-width of 44, so it stays inside the viewBox at every rasterised
    # size.
    if {$ring ne ""} {
        append b "<circle cx='$CX' cy='$CY' r='[expr {$R + 1.4}]' fill='none'"
        append b " stroke='#1b1f24' stroke-width='1.6'/>"
        append b "<circle cx='$CX' cy='$CY' r='[expr {$R + 2.8}]' fill='none'"
        append b " stroke='$ring' stroke-width='2.2'/>"
    }

    set svg "<svg xmlns='http://www.w3.org/2000/svg' width='$W' height='$W'"
    append svg " viewBox='0 0 $W $W'>$b</svg>"
    return [image create photo -data $svg -format [list svg -scaletowidth $size]]
}

# The darkening pie slice covering the remaining fraction, starting at twelve
# o'clock and sweeping clockwise. A full circle has no arc endpoint to name, so
# it is drawn as a plain disc instead of a degenerate path.
proc dial::Wedge {p} {
    variable CX; variable CY; variable R
    set deg [expr {$p * 360.0}]
    if {$deg >= 359.9} {
        return "<circle cx='$CX' cy='$CY' r='$R' fill='#0a0e14' opacity='0.72'/>"
    }
    set a  [expr {($deg - 90.0) * acos(-1) / 180.0}]
    set ex [expr {$CX + $R * cos($a)}]
    set ey [expr {$CY + $R * sin($a)}]
    set large [expr {$deg > 180 ? 1 : 0}]
    return "<path d='M $CX $CY L $CX [expr {$CY - $R}]\
            A $R $R 0 $large 1 $ex $ey Z' fill='#0a0e14' opacity='0.72'/>"
}

# Point a label at a freshly drawn dial and retire the photo it was showing.
# The delete happens after the configure, so the widget is never holding a
# photo that has gone. Returns the new photo for the caller to hand back next
# time.
proc dial::show {lbl old p state caption size {ring ""}} {
    set new [photo $p $state $size $ring]
    $lbl configure -image $new -text $caption -compound center \
        -foreground [ink $state]
    if {$old ne ""} { catch { image delete $old } }
    return $new
}
