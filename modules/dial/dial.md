# dial

## NAME

dial - a countdown drawn as a disc with a wedge that sweeps away

## SYNOPSIS

```tcl
package require dial

set lbl [ttk::label .d]
set photo ""
proc tick {} {
    set p [expr {$::left / double($::window)}]
    set ::photo [dial::show .d $::photo $p cooling "[expr {int($::left/1000)}]" 64]
}
```

## DESCRIPTION

A count running down wants a shape that cannot be read backwards. A shrinking bar still reads as a filling bar, and a bare number says nothing about how much of the wait is left. dial draws the MOBA/RPG ability idiom instead: a disc with a dark wedge over the time still to run, sweeping away clockwise, so the disc is fully dark when the count starts and fully lit when it expires. The caption in the middle settles it either way.

The disc is one SVG rendered through Tk 9's native svg photo format, so there are no image files to ship and no external renderer. Everything outside the disc is transparent: the photo composites onto whatever background the containing widget has, under any ttk theme.

Text is not in the SVG. nanosvg, the renderer behind Tk's svg photo format, parses `<text>` and draws nothing, so the caption rides on the widget as `-text ... -compound center` over the image.

A render costs about 0.2 ms including the photo delete, so a dial re-renders from scratch on every tick rather than caching angles. Callers own the photo's lifetime: hand the previous photo back and it is deleted once the widget is holding the new one.

## STATES

A dial has a face per state. Three come with the module:

**cooling**
: A count running down. The only state with a wedge, so it is the only one that reads `p`.

**held**
: The count has run out and nothing is acting on it yet.

**busy**
: Whatever the dial counts for is under way.

Each stock face is mid-toned enough to sit on a white background and light enough to sit on a near-black one, which is the constraint that picked them. None of them is green: green reads as go, and no state here is one to act on. A state the module does not know falls back to `cooling` rather than erroring, so a caption always has a disc under it.

## COMMANDS

**dial::photo** *p* *state* *size* ?*ring*?
: Render a dial and return the photo. *p* is the fraction of the count still to run, 1.0 at the start and 0.0 at expiry, clamped to that range and ignored by states with no wedge. *size* is the rasterised width in pixels. *ring* is a colour for a selection ring drawn outside the rims, empty for none. The caller owns the returned photo and must `image delete` it.

**dial::show** *label* *old* *p* *state* *caption* *size* ?*ring*?
: Render a dial, point *label* at it with *caption* centred over it in the state's ink, and delete the photo *old* (empty for the first draw). The delete happens after the configure, so the widget is never holding a photo that has gone. Returns the new photo, to be handed back as *old* next time.

**dial::ink** *state*
: The caption colour that goes with a state's face, for a caller styling the label itself.

**dial::face** *state* *gradient* *ink*
: Define or replace a face. *gradient* is a three-element list of colours - outer highlight, mid, rim - and *ink* is the caption colour. A caller with its own palette names the states it wants and leaves the rest at the stock colours.

## NOTES

The ring's geometry belongs to the module, so it scales with the face at any text scale; its colour arrives from the caller, because whether this dial is the selected one is a fact only the caller holds. The ring sits outside the disc, so a colour handed in cannot reach the face's legibility.

The ring is two strokes, not one. The `busy` face is amber, and a gold ring laid straight onto gold reads as a slightly fatter disc rather than as a selection; the dark stroke inside it is the separation that makes the ring a ring.

The disc carries two rims, because one cannot serve both backgrounds: the pale outer ring separates the disc from a dark background, the dark inner ring from a light one. Each is invisible against the background it is not for.

## REQUIREMENTS

Tcl 9 and Tk 9, the latter for the svg photo format. The module is Tk-free at load - it defines procedures and nothing else - so it can be required into an interpreter that has no Tk and may never draw.

## KEYWORDS

countdown, dial, timer, SVG, photo, wedge, Tk
