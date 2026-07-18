#!/usr/bin/env wish9.0
# The teatotal gallery: a launcher for the module demos, built from every
# module it demonstrates. ocmdline reads its argv, a streamtree lists the
# demos, tkdown paints the selected module's man page into the reading pane,
# each run's output streams into a streamdoc region below, deadman watches
# the running demo and kills its whole tree when the window closes mid-run,
# and every deferred callback is leash-armed so a torn-down gallery cannot
# be called back.
#
# Run it with bare wish:   wish9.0 demos/gallery.tcl
#                          wish9.0 demos/gallery.tcl --demo leash
#
# Try: click a row to read that module's man page; Run launches the demo as a
# subprocess and streams its output into a region below (each rerun opens a
# new one); View Source shows the demo file itself.

package require Tcl 9
package require Tk

set HERE [file dirname [file normalize [info script]]]
set ROOT [file dirname $HERE]
foreach md [glob -directory [file join $ROOT modules] -type d *] { ::tcl::tm::path add $md }
package require ocmdline
package require leash
package require streamtree
package require streamdoc
package require tkdown
package require deadman

# ---- the demos: adding one is one entry here -------------------------------
# file is under demos/, page is the module's man page at the repository root,
# runargs is what Run passes the demo (the CLI demo wants a command line).
set DEMOS [dict create \
    streamtree [dict create file streamtree-demo.tcl kind Tk page streamtree.md \
        runargs {} teaches "a sortable, streaming tree drawn in one text widget"] \
    streamdoc  [dict create file streamdoc-demo.tcl kind Tk page streamdoc.md \
        runargs {} teaches "a streaming document of foldable regions"] \
    tkdown     [dict create file tkdown-demo.tcl kind Tk page tkdown.md \
        runargs {} teaches "markdown painted onto a text widget"] \
    leash      [dict create file leash-demo.tcl kind Tk page leash.md \
        runargs {} teaches "deferred work that dies with its owner"] \
    searchfield [dict create file searchfield-demo.tcl kind Tk page searchfield.md \
        runargs {} teaches "the typed half of a query, merged by its consumer"] \
    querybuilder [dict create file querybuilder-demo.tcl kind Tk page querybuilder.md \
        runargs {} teaches "structured criteria as chips, facets declared as data"] \
    ocmdline   [dict create file ocmdline-demo.tcl kind CLI page ocmdline.md \
        runargs {oolong --temp 90 --time 180} teaches "parser and help from one declaration"] \
    deadman    [dict create file deadman-demo.tcl kind CLI page deadman.md \
        runargs {} teaches "a subprocess watchdog that owns the whole kill"] \
    jobpool    [dict create file jobpool-demo.tcl kind CLI page jobpool.md \
        runargs {} teaches "a worker pool that owns each job's lifecycle"] \
    jobloop    [dict create file jobloop-demo.tcl kind CLI page jobloop.md \
        runargs {} teaches "the same lifecycle on coroutines, no threads"] \
    yamlmuster [dict create file yamlmuster-demo.tcl kind CLI page yamlmuster.md \
        runargs {} teaches "partial validation with a bill, rules that can only declare"] \
]

# ---- argv through ocmdline --------------------------------------------------
set cl [ocmdline new gallery 1.0]
$cl synopsis {[options]}
$cl preamble {{The teatotal demo gallery.}}
$cl section pick {selection:}
$cl option --demo -section pick -arg name \
    -check {expr {[dict exists $::DEMOS $value] ? "" : "--demo: no demo named '$value'"}} \
    -fold {set pick $value} \
    -help {{Preselect this demo's row at start.}}
$cl reject -help {help is spelled --help}

switch [$cl asks $argv] {
    help    { $cl print; exit 0 }
    version { puts [$cl version_line]; exit 0 }
}
set pick streamtree
try {
    set r [$cl parse $argv]
} trap {OCMDLINE USAGE} {msg} {
    $cl abort $msg
}
foreach o [dict get $r occurrences] {
    set value  [dict get $o value]
    set suffix [dict get $o suffix]
    eval [$cl fold_of [dict get $o name]]
}

# ---- fonts: the host owns them, the modules bind onto them ------------------
foreach {name base extra} {
    GalBody   TkTextFont    {}
    GalBold   TkTextFont    {-weight bold}
    GalItalic TkTextFont    {-slant italic}
    GalBI     TkTextFont    {-weight bold -slant italic}
    GalMono   TkFixedFont   {}
    GalH1     TkTextFont    {-weight bold}
    GalH2     TkTextFont    {-weight bold}
    GalHead   TkHeadingFont {}
} {
    font create $name {*}[font actual $base] {*}$extra
}
font configure GalH1 -size [expr {[font configure GalBody -size] + 5}]
font configure GalH2 -size [expr {[font configure GalBody -size] + 2}]

# ---- the demo list: a streamtree of one row per demo ------------------------
oo::class create DemoRows {
    superclass ::streamtree::StreamTree
    variable Text OnPick
    constructor {parent onpick} {
        set OnPick $onpick
        my configure -listfont GalBody -headfont GalHead
        my setup $parent
        $Text configure -width 52 -height 9
        $Text tag configure demorow -foreground [my colour ink] -spacing3 2 \
            -wrap none
        $Text tag configure meta -foreground [my colour muted]
        $Text tag configure picked -background #dbe7f0
    }
    method subject_label {} { return "Demo" }
    method column_spec {} {
        # The teaches column is sized by its longest line, read from the one
        # data structure that defines the demos.
        set widest ""
        dict for {n d} $::DEMOS {
            set t [dict get $d teaches]
            if {[string length $t] > [string length $widest]} { set widest $t }
        }
        return [list [list teaches "What it teaches" $widest left 0] \
                     [list kind Kind {CLI} left 0]]
    }
    method row_tags {kind} { return demorow }
    method cell_values {node} {
        return [list [list teaches [my node_pget $node teaches]] \
                     [list kind [my node_pget $node kind]]]
    }
    method cell_tag {node col} { return meta }
    method on_row_rendered {id} {
        $Text tag bind [my node_field $id tag] <Button-1> \
            [list [self] pick [my node_field $id key]]
    }
    method pick {name} {
        $Text tag remove picked 1.0 end
        foreach id [my all_rendered_nodes] {
            if {[my node_field $id key] eq $name} {
                $Text tag add picked {*}[$Text tag ranges [my node_field $id tag]]
            }
        }
        uplevel #0 [list {*}$OnPick $name]
    }
}

# ---- the run log: a streamdoc of one region per run --------------------------
oo::class create RunLog {
    superclass ::streamdoc::StreamDoc
    variable Text
    constructor {parent} {
        my configure -font GalMono -autofollow 1
        my setup $parent
        $Text configure -height 8
        $Text tag configure hdr -font GalBold -spacing1 6
        $Text tag configure summary -foreground #6b7b88
        $Text tag bind hdr <Button-1> [list [self] hdr_click %x %y]
    }
    # While a run is live its payload carries no status, so the region has no
    # summary line; the closing payload_set gives it one to write.
    method summary_text {payload} {
        if {![dict exists $payload status]} { return "" }
        return "  exit [dict get $payload status] · [dict get $payload lines] line(s)"
    }
    method hdr_click {x y} {
        set n [my region_at [$Text index @$x,$y]]
        if {$n >= 0} { my toggle $n }
    }
}

# ---- the gallery ------------------------------------------------------------
oo::class create Gallery {
    mixin leash
    variable Rows Log Reader Selected Run Lines
    constructor {start} {
        set Run ""
        ttk::frame .bar
        pack .bar -side top -fill x
        ttk::button .bar.run -text Run -command [list [self] run]
        ttk::button .bar.src -text "View Source" -command [list [self] show_source]
        pack .bar.run .bar.src -side left -padx 4 -pady 4

        ttk::panedwindow .main -orient horizontal
        pack .main -fill both -expand 1
        ttk::frame .main.list
        ttk::frame .main.read
        .main add .main.list
        .main add .main.read -weight 1
        set Rows [DemoRows new .main.list [list [self] pick]]

        set Reader .main.read.t
        text $Reader -wrap word -padx 12 -pady 8 -borderwidth 0 -width 64 \
            -font GalBody -state disabled -yscrollcommand {.main.read.sb set}
        ttk::scrollbar .main.read.sb -command [list $Reader yview]
        pack .main.read.sb -side right -fill y
        pack $Reader -side left -fill both -expand 1
        ::tkdown::tags $Reader [dict create \
            body GalBody bold GalBold italic GalItalic bolditalic GalBI \
            mono GalMono h1 GalH1 h2 GalH2]
        $Reader tag configure base -foreground #102a43
        $Reader tag configure fence -font GalMono -background #eef2f6 \
            -lmargin1 16 -lmargin2 16 -spacing1 3 -spacing3 3
        $Reader tag configure srcmono -font GalMono

        ttk::frame .log
        pack .log -fill both -expand 0
        set Log [RunLog new .log]

        ttk::label .foot -anchor w -padding {8 3} -foreground #52606d -text \
            "Built from every module it demonstrates: ocmdline read the argv,\
 this list is a streamtree, the man pages paint through tkdown, runs stream\
 into a streamdoc, and leash owns every deferred callback."
        pack .foot -side bottom -fill x

        dict for {name d} $::DEMOS {
            $Rows insert "" demo $name [dict create label $name {*}$d]
        }
        $Rows pick $start
    }

    method pick {name} {
        set Selected $name
        my read_show [my slurp [file join $::ROOT modules $name [dict get $::DEMOS $name page]]] markdown
    }
    method show_source {} {
        my read_show [my slurp [file join $::ROOT modules $Selected [dict get $::DEMOS $Selected file]]] plain
    }
    method slurp {path} {
        set f [open $path r]
        set text [read $f]
        close $f
        return $text
    }
    method read_show {text how} {
        $Reader configure -state normal
        $Reader delete 1.0 end
        ::tkdown::forget $Reader
        if {$how eq "markdown"} {
            ::tkdown::body $Reader end $text base {base fence}
        } else {
            $Reader insert end $text srcmono
        }
        $Reader configure -state disabled
        $Reader see 1.0
    }

    # Launch the selected demo as a deadman-watched subprocess and stream
    # its output into a fresh streamdoc region. One run at a time:
    # streamdoc keeps one region open, so Run rests until the child exits.
    method run {} {
        set d [dict get $::DEMOS $Selected]
        set interp [expr {[dict get $d kind] eq "Tk" ? "wish9.0" : "tclsh9.0"}]
        set cmd [list $interp [file join $::ROOT modules $Selected [dict get $d file]] \
            {*}[dict get $d runargs]]
        set Lines 0
        $Log batch {
            $Log region_open [dict create]
            set m [$Log append_open]
            $Log emit $m "▾ $Selected · started [clock format [clock seconds] -format %T]\n" hdr
            $Log append_close $m
        }
        # The callbacks land through this object's instance-namespace `my`;
        # the destructor cancels the run, so a torn-down gallery leaves no
        # callback to fire.
        set Run [deadman::run $cmd -err stdout \
            -line [list [namespace which my] Line] \
            -done [list [namespace which my] Finish]]
        .bar.run state disabled
    }
    method Line {line} {
        $Log batch {
            set m [$Log append_open]
            $Log emit $m "  $line\n" {}
            $Log append_close $m
        }
        incr Lines
    }
    method Finish {res} {
        set status [dict get $res exit]
        if {[dict get $res signal] ne ""} {
            set status "killed ([dict get $res signal])"
        }
        set Run ""
        $Log batch {
            $Log payload_set [$Log live] [dict create status $status lines $Lines]
            $Log region_close
        }
        .bar.run state !disabled
    }

    # Closing the window mid-run kills the child rather than orphaning it: a
    # demo window with no gallery behind it would linger headless. cancel
    # kills the child's whole group and fires no callbacks into the
    # teardown.
    destructor {
        if {$Run ne ""} { deadman::cancel $Run }
    }
}

set gallery [Gallery new $pick]
wm title . "teatotal gallery"
wm protocol . WM_DELETE_WINDOW {
    $gallery destroy
    destroy .
}
