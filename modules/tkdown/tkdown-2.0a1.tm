package require Tcl 9
package provide tkdown 2.0a1

namespace eval ::tkdown {
    namespace export parse_inline segment_tables segment_code_fences \
        segment_blockquotes segment_lists table_to_markdown table_colwidths \
        tags runs prose body refit forget unregister table_scan table_spotlight
    # Emit state, one entry per registered widget: widget path -> {fonts
    # margin copystyle quotetags image_cmd on_block tables nextid spot fittok},
    # tables being id -> the table's entry (see the grid section), spot the
    # lit table's id and fittok the pending re-fit's after token.
    variable widgets [dict create]
    # table_colwidths' search state, keyed by a per-call id; see colwidths_memo.
    variable colmemo
}

# tkdown - a pragmatic markdown renderer for a Tk text widget.
#
# tkdown parses a block of markdown text into structured segments and inline
# runs, then paints those onto a text widget with the styling tags the emit
# half owns. It is not a full CommonMark implementation: it covers the block
# and inline forms a chat or transcript body actually carries - fenced code,
# blockquotes, GFM pipe tables, ATX headings, flat lists, code spans, and
# asterisk emphasis - and leaves the rest as literal text.
#
# The parse half (the segment_* splitters and parse_inline) is pure Tcl,
# needs no Tk, and runs under a bare tclsh. The splitters are layered: each
# sees a body the ones above it have already peeled, fences first, then
# quotes, then tables; lists split inside the emit walk. segment_blockquotes
# is parse-half only - the emit walk never calls it, and a host that wants
# quotes styled splits with it and paints each de-quoted run itself, the way
# it owns a code block's chrome. The emit half paints onto a widget
# registered with `tags`, and every td-* tag it configures is font-only or
# geometry-only. Colour always comes from the base tags the host stacks
# underneath, so the module owns faces and layout and the host owns the ink.

# Split a body into ordered {kind text} segments, where kind is
# "prose" or "code". A code segment is the content between a pair of triple
# backtick fence lines (```), captured verbatim with the fence markers and any
# language tag dropped. An unterminated fence renders its captured run as code.
# A body with no fence is one prose segment. Pure function on the raw body.
proc ::tkdown::segment_code_fences {body} {
    set segs [list]
    set buf  [list]
    set incode 0
    foreach line [split $body "\n"] {
        if {[regexp {^\s*```} $line]} {
            if {$incode} {
                lappend segs [list code [join $buf "\n"]]
            } elseif {[llength $buf]} {
                lappend segs [list prose [join $buf "\n"]]
            }
            set buf [list]
            set incode [expr {!$incode}]
            continue
        }
        lappend buf $line
    }
    if {[llength $buf]} {
        lappend segs [list [expr {$incode ? "code" : "prose"}] [join $buf "\n"]]
    }
    return $segs
}

# Split a body into ordered {kind text} segments, where kind is
# "normal" or "quote". A quote segment is a maximal run of markdown
# blockquote lines (each starting with ">"); its text is de-quoted, one
# leading "> " or ">" stripped per line. A bare blank line (no ">") ends a
# quote run, the strict markdown split.
proc ::tkdown::segment_blockquotes {body} {
    set segs [list]
    set buf  [list]   ;# accumulating normal lines
    set q    [list]   ;# accumulating de-quoted lines
    set mode normal
    foreach line [split $body "\n"] {
        if {[regexp {^>( ?)(.*)$} $line -> _sp rest]} {
            if {$mode eq "normal" && [llength $buf]} {
                lappend segs [list normal [join $buf "\n"]]
                set buf [list]
            }
            set mode quote
            lappend q $rest
        } else {
            if {$mode eq "quote" && [llength $q]} {
                lappend segs [list quote [join $q "\n"]]
                set q [list]
            }
            set mode normal
            lappend buf $line
        }
    }
    if {[llength $buf]} { lappend segs [list normal [join $buf "\n"]] }
    if {[llength $q]}   { lappend segs [list quote  [join $q "\n"]] }
    return $segs
}

# Split a prose run into ordered {kind payload} segments, where kind is
# "normal" (payload is raw text) or "table" (payload is a parsed GFM pipe
# table). A table is a header line, a delimiter line of dashes with optional
# alignment colons, and zero or more body rows, in the lenient GitHub form.
# Both the header and the delimiter must carry a "|" so a setext underline
# ("Heading" / "---") or a thematic break is never mistaken for a one-column
# table; single-column tables therefore need the explicit "| h |" / "| - |"
# form, as in cmark-gfm. Callers strip code fences first, so a fenced "|---|"
# never reaches here.
#
# A table payload is {align <list> rows <list-of-rows>}: align is one of
# left/right/center per column, rows[0] is the header, and every row is
# normalised to the header's column count (short rows padded, long truncated,
# per GFM).
proc ::tkdown::segment_tables {text} {
    set lines [split $text "\n"]
    set n [llength $lines]
    set segs [list]
    set buf  [list]
    set i 0
    while {$i < $n} {
        set tbl [::tkdown::table_at $lines $i]
        if {$tbl eq ""} {
            lappend buf [lindex $lines $i]
            incr i
            continue
        }
        if {[llength $buf]} {
            lappend segs [list normal [join $buf "\n"]]
            set buf [list]
        }
        lassign $tbl payload next
        lappend segs [list table $payload]
        set i $next
    }
    if {[llength $buf]} { lappend segs [list normal [join $buf "\n"]] }
    return $segs
}

# If a GFM table starts at line index $i of $lines, return {payload next},
# where next is the index just past the last consumed table line; else "".
# The header is at $i, the delimiter at $i+1, body rows from $i+2 until a
# blank line or the end of the run.
proc ::tkdown::table_at {lines i} {
    set n [llength $lines]
    if {$i + 1 >= $n} { return "" }
    set hdr_line [lindex $lines $i]
    if {[string trim $hdr_line] eq ""} { return "" }
    if {[string first "|" $hdr_line] < 0} { return "" }
    set delim_line [lindex $lines [expr {$i + 1}]]
    if {[string first "|" $delim_line] < 0} { return "" }
    set header [::tkdown::split_row $hdr_line]
    set ncol [llength $header]
    if {$ncol < 1} { return "" }
    set delim [::tkdown::split_row $delim_line]
    if {[llength $delim] != $ncol} { return "" }
    foreach c $delim {
        if {![regexp {^:?-+:?$} $c]} { return "" }
    }
    set align [list]
    foreach c $delim { lappend align [::tkdown::delim_align $c] }
    set rows [list [::tkdown::norm_row $header $ncol]]
    set j [expr {$i + 2}]
    while {$j < $n} {
        set ln [lindex $lines $j]
        if {[string trim $ln] eq ""} break
        lappend rows [::tkdown::norm_row \
            [::tkdown::split_row $ln] $ncol]
        incr j
    }
    return [list [dict create align $align rows $rows] $j]
}

# The column alignment a delimiter cell encodes: a leading colon means left,
# a trailing colon right, both center, neither the left default.
proc ::tkdown::delim_align {cell} {
    set l [string match {:*} $cell]
    set r [string match {*:} $cell]
    if {$l && $r} { return center }
    if {$r}       { return right }
    return left
}

# Split one table row into trimmed cells. Splits on unescaped "|"; a
# pipe-bounded row drops its empty leading/trailing cell; "\|" becomes a
# literal "|" in the cell (parse_inline's escape map covers only \` \* \\, so
# a surviving "\|" would leak a backslash into the rendered cell).
proc ::tkdown::split_row {line} {
    set line [string trim [string trimright $line "\r"]]
    set cells [list]
    set cur ""
    set len [string length $line]
    for {set k 0} {$k < $len} {incr k} {
        set ch [string index $line $k]
        if {$ch eq "\\" && [string index $line [expr {$k + 1}]] eq "|"} {
            append cur "|"
            incr k
            continue
        }
        if {$ch eq "|"} {
            lappend cells $cur
            set cur ""
            continue
        }
        append cur $ch
    }
    lappend cells $cur
    if {[llength $cells] > 1 && [string trim [lindex $cells 0]] eq "" \
            && [string index $line 0] eq "|"} {
        set cells [lrange $cells 1 end]
    }
    if {[llength $cells] > 1 && [string trim [lindex $cells end]] eq "" \
            && [string index $line end] eq "|"} {
        set cells [lrange $cells 0 end-1]
    }
    set out [list]
    foreach c $cells { lappend out [string trim $c] }
    return $out
}

proc ::tkdown::norm_row {cells ncol} {
    while {[llength $cells] < $ncol} { lappend cells "" }
    if {[llength $cells] > $ncol} { set cells [lrange $cells 0 [expr {$ncol - 1}]] }
    return $cells
}

# A table payload ({align rows}, the segment_tables shape) back to GFM text.
# Cells re-escape the "|" that split_row decoded, so the text round-trips
# through segment_tables to the same payload. The source's padding and its
# left-colon spelling of a left column are not in the payload, so the
# delimiter row is regenerated canonically.
proc ::tkdown::table_to_markdown {payload} {
    set lines [list]
    set first 1
    foreach row [dict get $payload rows] {
        set cells [list]
        foreach cell $row { lappend cells [string map {"|" "\\|"} $cell] }
        lappend lines "| [join $cells { | }] |"
        if {$first} {
            set d [list]
            foreach a [dict get $payload align] {
                switch -- $a {
                    right   { lappend d "---:" }
                    center  { lappend d ":---:" }
                    default { lappend d "---" }
                }
            }
            lappend lines "| [join $d { | }] |"
            set first 0
        }
    }
    return [join $lines "\n"]
}

# Column widths in pixels for a table whose cells word-wrap within avail
# pixels. rows is a list of rows, a row a list of cells, a cell a list of
# token widths (its words measured in the font they paint in); em is the
# width of one em (or "0") and space of one space, both in the body font.
# Pure: the caller measures, so it runs without Tk.
#
# A column's max-content is its widest cell laid on one line. When the
# max-contents fit, they are the answer. Otherwise each column has a floor,
# its widest token but no more than eight ems or an equal share of avail,
# below which a token character-wraps; when the floors alone fill avail,
# they are the answer. Between the two the widths are searched rather than
# shrunk. The cost of an allocation is the table's line count (each row as
# tall as its tallest cell under greedy word wrap) plus one per
# character-wrap, since a broken word reads worse than a wrapped one. Three
# seeds - CSS auto layout, a proportional shrink of the max-contents, and a
# greedy climb from the floors - are each refined by moving pixels between
# column pairs while the cost falls, and the cheapest result is returned.
# The proportional shrink being a seed, the result never costs more than it.
proc ::tkdown::table_colwidths {rows avail em space} {
    set ncol 0
    foreach row $rows {
        if {[llength $row] > $ncol} { set ncol [llength $row] }
    }
    if {$ncol == 0} { return {} }
    set toks [lrepeat $ncol 0]
    set maxs [lrepeat $ncol 0]
    foreach row $rows {
        for {set j 0} {$j < $ncol} {incr j} {
            set cell [lindex $row $j]
            set full 0
            set widest 0
            foreach t $cell {
                if {$t > $widest} { set widest $t }
                incr full $t
            }
            if {[llength $cell] > 1} {
                incr full [expr {([llength $cell] - 1) * $space}]
            }
            if {$widest > [lindex $toks $j]} { lset toks $j $widest }
            if {$full > [lindex $maxs $j]} { lset maxs $j $full }
        }
    }
    if {[tcl::mathop::+ {*}$maxs] <= $avail} { return $maxs }
    set cap [expr {min(8 * $em, $avail / $ncol)}]
    set mins [list]
    foreach t $toks { lappend mins [expr {min($t, $cap)}] }
    if {[tcl::mathop::+ {*}$mins] >= $avail} { return $mins }

    set memo [::tkdown::colwidths_memo $rows $ncol $space]
    set best {}
    set bestc -1
    foreach seed [::tkdown::colwidths_seeds $memo $mins $maxs $avail] {
        set w [::tkdown::colwidths_search $memo $seed $mins $maxs]
        set c [::tkdown::colwidths_cost $memo $w]
        if {$bestc < 0 || $c < $bestc} {
            set best $w
            set bestc $c
        }
    }
    ::tkdown::colwidths_forget $memo
    return $best
}

# The search's scratch state: the rows split into columns, and a cache of
# each column's per-row line counts by width. The search asks for the same
# column at the same width many times over, and a table of a few hundred
# words would otherwise rewrap every cell for every trial.
proc ::tkdown::colwidths_memo {rows ncol space} {
    variable colmemo
    set id [incr colmemo(next)]
    set cols [list]
    for {set j 0} {$j < $ncol} {incr j} {
        set col [list]
        foreach row $rows { lappend col [lindex $row $j] }
        lappend cols $col
    }
    set colmemo($id,cols) $cols
    set colmemo($id,space) $space
    return $id
}

proc ::tkdown::colwidths_forget {memo} {
    variable colmemo
    array unset colmemo $memo,*
}

# Column j's line count per row at width w, character-wraps penalised.
proc ::tkdown::colwidths_lines {memo j w} {
    variable colmemo
    set key $memo,$j,$w
    if {![info exists colmemo($key)]} {
        set space $colmemo($memo,space)
        set out [list]
        foreach cell [lindex $colmemo($memo,cols) $j] {
            lappend out [::tkdown::cell_lines $cell $w $space]
        }
        set colmemo($key) $out
    }
    return $colmemo($key)
}

# Lines of one cell at width w under greedy word wrap. A token wider than w
# starts its own line and breaks every w pixels; each break costs one more
# on top of the line it adds when penalise is set.
proc ::tkdown::cell_lines {cell w space {penalise 1}} {
    set lines 1
    set cur -1
    foreach t $cell {
        if {$t > $w && $w > 0} {
            if {$cur >= 0} { incr lines }
            set wraps [expr {($t - 1) / $w}]
            incr lines $wraps
            if {$penalise} { incr lines $wraps }
            set cur [expr {$t - $wraps * $w}]
        } elseif {$cur < 0} {
            set cur $t
        } elseif {$cur + $space + $t <= $w} {
            set cur [expr {$cur + $space + $t}]
        } else {
            incr lines
            set cur $t
        }
    }
    return $lines
}

# The cost of an allocation: each row's tallest cell, summed.
proc ::tkdown::colwidths_cost {memo widths} {
    set tallest {}
    set j 0
    foreach cw $widths {
        set col [::tkdown::colwidths_lines $memo $j $cw]
        if {$j == 0} {
            set tallest $col
        } else {
            set tallest [lmap a $tallest b $col {expr {max($a, $b)}}]
        }
        incr j
    }
    return [tcl::mathop::+ 0 {*}$tallest]
}

# The starting allocations: CSS auto layout (the excess over the floors
# shared in proportion to each column's max-content less its floor), the
# max-contents scaled to avail, and a greedy climb from the floors.
proc ::tkdown::colwidths_seeds {memo mins maxs avail} {
    set summin [tcl::mathop::+ {*}$mins]
    set summax [tcl::mathop::+ {*}$maxs]
    set spare [expr {$avail - $summin}]
    set room [expr {$summax - $summin}]
    set css [lmap lo $mins hi $maxs {
        expr {$lo + ($hi - $lo) * $spare / $room}
    }]
    set prop [lmap hi $maxs { expr {$hi * $avail / $summax} }]
    return [list \
        [::tkdown::colwidths_fill $css $mins $maxs $avail] \
        [::tkdown::colwidths_fill $prop $mins $maxs $avail] \
        [::tkdown::colwidths_climb $memo $mins $maxs $avail]]
}

# Pin an allocation into [mins, maxs] summing to avail: clamp each column,
# then hand the difference to the columns with room, first to last.
proc ::tkdown::colwidths_fill {widths mins maxs avail} {
    set out [lmap cw $widths lo $mins hi $maxs {
        expr {min(max($cw, $lo), $hi)}
    }]
    set left [expr {$avail - [tcl::mathop::+ {*}$out]}]
    for {set j 0} {$j < [llength $out] && $left != 0} {incr j} {
        if {$left > 0} {
            set add [expr {min([lindex $maxs $j] - [lindex $out $j], $left)}]
        } else {
            set add [expr {max([lindex $mins $j] - [lindex $out $j], $left)}]
        }
        lset out $j [expr {[lindex $out $j] + $add}]
        set left [expr {$left - $add}]
    }
    return $out
}

# From the floors, widen the column whose next breakpoint saves the most
# cost per pixel, while the pixels last.
proc ::tkdown::colwidths_climb {memo mins maxs avail} {
    set w $mins
    set spare [expr {$avail - [tcl::mathop::+ {*}$mins]}]
    set cost [::tkdown::colwidths_cost $memo $w]
    while {$spare > 0} {
        set bestj -1
        set bestrate 0
        set j 0
        foreach cw $w {
            set nb [::tkdown::colwidths_next $memo $j $cw [lindex $maxs $j]]
            if {$nb >= 0 && $nb - $cw <= $spare} {
                set trial $w
                lset trial $j $nb
                set c [::tkdown::colwidths_cost $memo $trial]
                set rate [expr {double($cost - $c) / ($nb - $cw)}]
                if {$rate > $bestrate} {
                    set bestj $j
                    set bestrate $rate
                    set bestw $nb
                    set bestc $c
                }
            }
            incr j
        }
        if {$bestj < 0} break
        set spare [expr {$spare - ($bestw - [lindex $w $bestj])}]
        lset w $bestj $bestw
        set cost $bestc
    }
    return [::tkdown::colwidths_fill $w $mins $maxs $avail]
}

# Local search over pair moves: one column up to one of its next three
# breakpoints, the pixels taken from another column above its floor, a move
# kept when the cost falls, until no move lowers it.
proc ::tkdown::colwidths_search {memo w mins maxs} {
    set ncol [llength $w]
    set cost [::tkdown::colwidths_cost $memo $w]
    set improved 1
    while {$improved} {
        set improved 0
        for {set j 0} {$j < $ncol && !$improved} {incr j} {
            set from [lindex $w $j]
            for {set k 0} {$k < 3 && !$improved} {incr k} {
                set nb [::tkdown::colwidths_next $memo $j $from [lindex $maxs $j]]
                if {$nb < 0} break
                set from $nb
                set step [expr {$nb - [lindex $w $j]}]
                for {set i 0} {$i < $ncol} {incr i} {
                    if {$i == $j} continue
                    if {[lindex $w $i] - $step < [lindex $mins $i]} continue
                    set trial $w
                    lset trial $j $nb
                    lset trial $i [expr {[lindex $w $i] - $step}]
                    set c [::tkdown::colwidths_cost $memo $trial]
                    if {$c < $cost} {
                        set w $trial
                        set cost $c
                        set improved 1
                        break
                    }
                }
            }
        }
    }
    return $w
}

# The smallest width above cur, up to max, at which some cell of column j
# takes fewer lines; -1 when none does. A cell's line count never rises with
# the width, so each cell's breakpoint is a binary search. max is always the
# column's max-content, so the cache keys on j and cur alone.
proc ::tkdown::colwidths_next {memo j cur max} {
    variable colmemo
    set key $memo,next,$j,$cur
    if {[info exists colmemo($key)]} { return $colmemo($key) }
    set space $colmemo($memo,space)
    set best -1
    foreach cell [lindex $colmemo($memo,cols) $j] \
            now [::tkdown::colwidths_lines $memo $j $cur] \
            top [::tkdown::colwidths_lines $memo $j $max] {
        if {$now < 2 || $top >= $now} continue
        set lo [expr {$cur + 1}]
        set hi $max
        while {$lo < $hi} {
            set mid [expr {($lo + $hi) / 2}]
            if {[::tkdown::cell_lines $cell $mid $space] < $now} {
                set hi $mid
            } else {
                set lo [expr {$mid + 1}]
            }
        }
        if {$best < 0 || $lo < $best} { set best $lo }
    }
    set colmemo($key) $best
    return $best
}

# Split a normal (table-free) run into ordered {kind payload} segments, where
# kind is "normal" (payload is raw text) or "list" (payload is a flat list of
# items). A list is a maximal run of lines each opening with "- ", "* ", or
# "N. " (ASCII digits, one dot, one space) at the very start of the line; each
# such line is one item. A list item's payload is {num text}: num is "" for a
# bullet ("- "/"* ") or the item's own digits for an ordered ("N. ") item, and
# text is the rest of the line, still markdown for the inline pass. Flat only:
# a leading-space (indented) or nested marker matches nothing here and stays in
# a normal segment, a documented limit.
proc ::tkdown::segment_lists {text} {
    set segs  [list]
    set buf   [list]   ;# accumulating normal lines
    set items [list]   ;# accumulating {num text} list items
    foreach line [split $text "\n"] {
        if {[regexp {^[-*] (.*)$} $line -> rest]} {
            set num ""
        } elseif {[regexp {^([0-9]+)\. (.*)$} $line -> num rest]} {
            # num and rest set by the match
        } else {
            if {[llength $items]} {
                lappend segs [list list $items]
                set items [list]
            }
            lappend buf $line
            continue
        }
        if {[llength $buf]} {
            lappend segs [list normal [join $buf "\n"]]
            set buf [list]
        }
        lappend items [list $num $rest]
    }
    if {[llength $buf]}   { lappend segs [list normal [join $buf "\n"]] }
    if {[llength $items]} { lappend segs [list list $items] }
    return $segs
}

# Parse one prose run into styled inline runs. Returns an ordered list of
# {style chunk} pairs; style is one of plain, code, bold, italic, bolditalic,
# and chunk is the text to display with the markdown markers removed. Adjacent
# plain runs are coalesced. Callers strip fenced code and blockquotes first,
# so this never sees a ``` fence. The rules:
#   - code spans (one or two backticks) win over emphasis, so asterisks inside
#     `code` are never styled;
#   - emphasis is asterisks only (*, **, ***): underscores stay literal, so
#     snake_case, __init__ and the like are left alone;
#   - an opener needs a non-space char after it and a closer a non-space char
#     before it (flanking), so "3 * 4" and "* item" stay literal;
#   - \`, \* and \\ escape a literal backtick, asterisk and backslash; every
#     other backslash is kept verbatim (paths and regex carry many).
proc ::tkdown::parse_inline {text} {
    # Escapes go to private-use sentinels so the marker scans never meet them;
    # any stray sentinel in the raw input is dropped first.
    set bt \uE000 ;# escaped backtick  -> literal `
    set st \uE001 ;# escaped asterisk  -> literal *
    set bs \uE002 ;# escaped backslash -> literal \
    set text [string map [list $bt {} $st {} $bs {}] $text]
    set text [string map [list {\`} $bt {\*} $st {\\} $bs] $text]

    # Pass A: peel off code spans; the gaps between them are prose.
    set segs [list]
    set buf ""
    set i 0
    set n [string length $text]
    while {$i < $n} {
        if {[string index $text $i] ne "`"} {
            append buf [string index $text $i]
            incr i
            continue
        }
        set j $i
        while {$j < $n && [string index $text $j] eq "`"} { incr j }
        set fence [expr {$j - $i}]
        set close -1
        if {$fence <= 2} {
            set close [::tkdown::inline_close_code $text $j $fence]
        }
        if {$close < 0} {
            append buf [string range $text $i [expr {$j - 1}]]
            set i $j
            continue
        }
        if {$buf ne ""} { lappend segs prose $buf; set buf "" }
        set content [string range $text $j [expr {$close - 1}]]
        if {[string length $content] >= 2 && [string index $content 0] eq " " \
                && [string index $content end] eq " " \
                && [string trim $content] ne ""} {
            set content [string range $content 1 end-1]
        }
        lappend segs code $content
        set i [expr {$close + $fence}]
    }
    if {$buf ne ""} { lappend segs prose $buf }

    # Pass B: emphasis within each prose gap; unescape every emitted chunk.
    set runs [list]
    foreach {kind chunk} $segs {
        if {$kind eq "code"} {
            lappend runs [list code [::tkdown::inline_unescape $chunk]]
            continue
        }
        foreach run [::tkdown::inline_emphasis $chunk] {
            lassign $run style stext
            lappend runs [list $style [::tkdown::inline_unescape $stext]]
        }
    }
    return $runs
}

# Index of the closing backtick run of exactly `fence` backticks at or after
# `from`, or -1. Runs of a different length are literal content, so skipped.
proc ::tkdown::inline_close_code {s from fence} {
    set n [string length $s]
    set i $from
    while {$i < $n} {
        if {[string index $s $i] ne "`"} { incr i; continue }
        set k $i
        while {$k < $n && [string index $s $k] eq "`"} { incr k }
        if {($k - $i) == $fence} { return $i }
        set i $k
    }
    return -1
}

# Split one prose run into {style chunk} runs on asterisk emphasis. plain runs
# are coalesced; chunks still carry escape sentinels (the caller unescapes).
proc ::tkdown::inline_emphasis {s} {
    set runs [list]
    set plain ""
    set i 0
    set n [string length $s]
    while {$i < $n} {
        if {[string index $s $i] ne "*"} {
            append plain [string index $s $i]
            incr i
            continue
        }
        set j $i
        while {$j < $n && [string index $s $j] eq "*"} { incr j }
        set runlen [expr {$j - $i}]
        set style ""
        switch -- $runlen {
            1 { set style italic }
            2 { set style bold }
            3 { set style bolditalic }
        }
        set close -1
        if {$style ne ""} {
            set after [string index $s $j]
            if {$after ne "" && ![string is space $after]} {
                set close [::tkdown::inline_close_emph $s $j $runlen]
            }
        }
        if {$close < 0} {
            append plain [string range $s $i [expr {$j - 1}]]
            set i $j
            continue
        }
        if {$plain ne ""} { lappend runs [list plain $plain]; set plain "" }
        lappend runs [list $style [string range $s $j [expr {$close - 1}]]]
        set i [expr {$close + $runlen}]
    }
    if {$plain ne ""} { lappend runs [list plain $plain] }
    return $runs
}

# Index of a closing asterisk run of exactly `runlen` whose preceding char is
# non-space (flanking), at or after `from`; -1 if none.
proc ::tkdown::inline_close_emph {s from runlen} {
    set n [string length $s]
    set i $from
    while {$i < $n} {
        if {[string index $s $i] ne "*"} { incr i; continue }
        set k $i
        while {$k < $n && [string index $s $k] eq "*"} { incr k }
        if {($k - $i) == $runlen} {
            set before [string index $s [expr {$i - 1}]]
            if {$before ne "" && ![string is space $before]} { return $i }
        }
        set i $k
    }
    return -1
}

proc ::tkdown::inline_unescape {s} {
    return [string map [list \uE000 "`" \uE001 "*" \uE002 "\\"] $s]
}

# Register a text widget for emission and configure the td-* faces on it.
# fonts is a dict of Tk font names: body bold italic bolditalic mono are
# required; h1 h2 h3 are optional heading faces falling back to bold. Extra
# keys are kept but nothing draws with them. The options are those refit
# re-sets: -margin {left right} (or one n for both) is the host's base margin
# in screen distance, -copystyle the ttk style of a grid's copy button, and
# -quotetags, -image_cmd and -on_block are kept for the block emitters.
# Registration opens the widget's table registry; the entry dies with the
# widget. Registering a widget again keeps the tables it already holds.
proc ::tkdown::tags {w fonts args} {
    variable widgets
    foreach k {body bold italic bolditalic mono} {
        if {![dict exists $fonts $k]} {
            error "tkdown: fonts dict missing \"$k\""
        }
    }
    set reg [dict create fonts $fonts margin {0 0} copystyle Copy.TButton \
        quotetags {} image_cmd {} on_block {} \
        tables [dict create] nextid 0 spot "" fittok ""]
    if {[dict exists $widgets $w]} {
        foreach k {tables nextid spot fittok} {
            dict set reg $k [dict get $widgets $w $k]
        }
    }
    set reg [::tkdown::options $w $reg $args]
    dict set widgets $w $reg
    # Later-configured tags win on -font where they stack: headings first so
    # emphasis spans inside a heading still restyle.
    foreach lvl {h1 h2 h3} {
        set f [expr {[dict exists $fonts $lvl]
            ? [dict get $fonts $lvl] : [dict get $fonts bold]}]
        $w tag configure td-$lvl -font $f
    }
    $w tag configure td-bold       -font [dict get $fonts bold]
    $w tag configure td-italic     -font [dict get $fonts italic]
    $w tag configure td-bolditalic -font [dict get $fonts bolditalic]
    $w tag configure td-code       -font [dict get $fonts mono]
    ::tkdown::margins $w
    # A grid's frame, cells and copy button share one bindtag per pane: the
    # wheel goes on to w with its delta untouched (a cell would otherwise
    # take it and the pane stop scrolling under the pointer), and crossing
    # into or out of a table shows or hides its copy button.
    set bt tkdown.grid$w
    foreach ev {<MouseWheel> <Shift-MouseWheel> <TouchpadScroll>} {
        bind $bt $ev "[list event generate $w $ev -delta] %D; break"
    }
    bind $bt <Enter> [list ::tkdown::table_hover $w %W]
    bind $bt <Leave> [list after idle [list ::tkdown::table_hover_check $w %W]]
    foreach {ev script} [list <Destroy> [list ::tkdown::unregister $w] \
            <Configure> [list ::tkdown::refit_later $w]] {
        if {[string first $script [bind $w $ev]] < 0} {
            bind $w $ev +$script
        }
    }
}

# Fold option-value pairs into a registry entry and return it. -margin is
# held as two pixel counts.
proc ::tkdown::options {w reg opts} {
    if {[llength $opts] % 2} {
        error "tkdown: option \"[lindex $opts end]\" has no value"
    }
    foreach {opt val} $opts {
        switch -- $opt {
            -margin {
                if {[llength $val] == 1} { set val [list $val $val] }
                if {[llength $val] != 2} {
                    error "tkdown: -margin wants {left right} or one distance"
                }
                dict set reg margin [lmap d $val { winfo pixels $w $d }]
            }
            -copystyle { dict set reg copystyle $val }
            -quotetags { dict set reg quotetags $val }
            -image_cmd { dict set reg image_cmd $val }
            -on_block  { dict set reg on_block $val }
            default {
                error "tkdown: unknown option \"$opt\": want -margin,\
                    -copystyle, -quotetags, -image_cmd or -on_block"
            }
        }
    }
    return $reg
}

# The geometry tags, offset from the host's margin. td-list's lmargin1 sets
# the marker 10 px in; lmargin2 sets item text (and any wrapped
# continuation) a marker-width further, and the tab stop there lands the
# text after the marker. td-quote insets a quote block past its bar. A grid
# sits at the margin itself, and its width is capped by both margins.
proc ::tkdown::margins {w} {
    variable widgets
    lassign [dict get $widgets $w margin] l r
    $w tag configure td-list -lmargin1 [expr {$l + 10}] \
        -lmargin2 [expr {$l + 30}] -tabs [expr {$l + 30}] -rmargin $r
    $w tag configure td-quote -lmargin1 [expr {$l + 14}] \
        -lmargin2 [expr {$l + 14}] -rmargin $r
    $w tag configure td-tblwin -lmargin1 $l -lmargin2 $l -rmargin $r
}

# Drop the widget from the registry, its grids and their bindings with it.
proc ::tkdown::unregister {w} {
    variable widgets
    if {![dict exists $widgets $w]} return
    ::tkdown::forget $w
    set bt tkdown.grid$w
    foreach ev [bind $bt] { bind $bt $ev {} }
    dict unset widgets $w
}

# Insert one prose run's inline spans at idx. Each styled chunk stacks its
# td-* face over baseTags, so only the -font changes and the host's colour
# and margins hold.
proc ::tkdown::runs {w idx text baseTags} {
    foreach run [::tkdown::parse_inline $text] {
        lassign $run style chunk
        set tags $baseTags
        switch -- $style {
            code       { lappend tags td-code }
            bold       { lappend tags td-bold }
            italic     { lappend tags td-italic }
            bolditalic { lappend tags td-bolditalic }
        }
        $w insert $idx $chunk $tags
    }
}

# Insert a prose-or-table run at idx, closed by suffix (a rendering concern,
# passed rather than parsed). A run with no GFM pipe table goes straight to
# the heading-and-inline pass; a run carrying one is split by segment_tables
# and rendered piecewise, each table as a grid (emit_table).
proc ::tkdown::prose {w idx text baseTags {suffix "\n\n"}} {
    set segs [::tkdown::segment_tables $text]
    set has_table 0
    foreach s $segs { if {[lindex $s 0] eq "table"} { set has_table 1; break } }
    if {!$has_table} {
        ::tkdown::emit_normal $w $idx $text $baseTags
    } else {
        foreach s $segs {
            lassign $s kind payload
            if {$kind eq "table"} {
                ::tkdown::emit_table $w $idx $payload $baseTags
            } else {
                ::tkdown::emit_normal $w $idx $payload $baseTags
            }
        }
    }
    if {$suffix ne ""} { $w insert $idx $suffix $baseTags }
}

# Insert a fenced body at idx: prose segments through prose (headings and
# tables included), fenced code verbatim, one closing newline under baseTags.
# Code goes in under codeTags, named by the host outright, because a code
# block's chrome (margins, ink) is host styling, not a tkdown face.
proc ::tkdown::body {w idx text baseTags codeTags} {
    foreach seg [::tkdown::segment_code_fences $text] {
        lassign $seg kind chunk
        if {$kind eq "code"} {
            $w insert $idx "$chunk\n" $codeTags
        } else {
            ::tkdown::prose $w $idx $chunk $baseTags "\n"
        }
    }
    $w insert $idx "\n" $baseTags
}

# Re-set any of tags' options, then bring the pane up to date with them:
# margins re-derived, copy buttons restyled, tables whose window has gone
# from the text dropped, and every built grid re-fitted on the next idle
# pass. A resize or a reading-font change needs only the re-fit, which the
# pane's <Configure> already schedules; a host calls refit after a font
# change or to change an option.
proc ::tkdown::refit {w args} {
    variable widgets
    if {![dict exists $widgets $w]} return
    dict set widgets $w [::tkdown::options $w [dict get $widgets $w] $args]
    ::tkdown::margins $w
    set style [::tkdown::copy_style $w]
    dict for {id t} [dict get $widgets $w tables] {
        set f [dict get $t frame]
        if {[winfo exists $f.copy]} { $f.copy configure -style $style }
    }
    ::tkdown::table_prune $w
    ::tkdown::refit_later $w
}

# Schedule one fitting pass over the built grids. <Configure> fires per
# pixel through a sash drag and each fit walks every cell, so the pass is
# debounced to a single idle callback.
proc ::tkdown::refit_later {w} {
    variable widgets
    if {![dict exists $widgets $w]} return
    after cancel [dict get $widgets $w fittok]
    dict set widgets $w fittok [after idle [list ::tkdown::refit_run $w]]
}

proc ::tkdown::refit_run {w} {
    variable widgets
    if {![dict exists $widgets $w]} return
    dict set widgets $w fittok ""
    dict for {id t} [dict get $widgets $w tables] {
        if {![winfo exists [dict get $t frame]]} continue
        ::tkdown::table_paint $w $id
        ::tkdown::table_fit $w $id
    }
}

# Drop w's tables: destroy every grid, unset every tbl#m<N> mark, empty the
# registry. A `delete 1.0 end` alone would leave the marks behind, piled at
# 1.0 across reloads. Registration survives; call before a re-render, and
# the table ids start again from one.
proc ::tkdown::forget {w} {
    variable widgets
    if {![dict exists $widgets $w]} return
    after cancel [dict get $widgets $w fittok]
    dict for {id t} [dict get $widgets $w tables] {
        after cancel [dict get $t fbtok]
        destroy [dict get $t frame]
    }
    if {[winfo exists $w]} {
        foreach m [$w mark names] {
            if {[string match tbl#m* $m]} { $w mark unset $m }
        }
    }
    dict set widgets $w tables [dict create]
    dict set widgets $w nextid 0
    dict set widgets $w spot ""
    dict set widgets $w fittok ""
}

# One normal (table-free) run, split into peer blocks that re-join on the
# newlines the splits consumed: a list run (its own td-list hanging indent),
# any ATX heading line lifted out under td-h1/h2/h3 (levels 4-6 render as h3),
# and plain text, inline spans parsed inside each. A heading is a #{1,6} run
# plus a space opening a line. A run with no list and no heading emits
# byte-for-byte as one inline pass.
proc ::tkdown::emit_normal {w idx text baseTags} {
    set blocks [list]
    foreach seg [::tkdown::segment_lists $text] {
        lassign $seg kind payload
        if {$kind eq "list"} {
            lappend blocks [list list $payload]
            continue
        }
        set buf [list]
        foreach line [split $payload "\n"] {
            if {[regexp {^(#{1,6}) (.*)$} $line -> marks rest]} {
                if {[llength $buf]} {
                    lappend blocks [list text [join $buf "\n"]]
                    set buf [list]
                }
                set lvl [string length $marks]
                if {$lvl > 3} { set lvl 3 }
                lappend blocks [list td-h$lvl $rest]
            } else {
                lappend buf $line
            }
        }
        if {[llength $buf]} { lappend blocks [list text [join $buf "\n"]] }
    }
    set first 1
    foreach b $blocks {
        lassign $b kind chunk
        if {!$first} { $w insert $idx "\n" $baseTags }
        switch -- $kind {
            list    { ::tkdown::emit_list_items $w $idx $chunk $baseTags }
            text    { ::tkdown::runs $w $idx $chunk $baseTags }
            default { ::tkdown::runs $w $idx $chunk [concat $baseTags [list $kind]] }
        }
        set first 0
    }
}

# Emit one parsed list as consecutive logical lines under td-list, its hanging
# indent. Each item is a marker (a bullet glyph for an unordered item, the
# item's own number and a dot for an ordered one) then a tab then the item
# text through the inline-run path, so markdown inside an item still styles.
# The tab lands the text at td-list's lmargin2, aligning it with the wrap.
proc ::tkdown::emit_list_items {w idx items baseTags} {
    set tags [concat $baseTags [list td-list]]
    set first 1
    foreach item $items {
        lassign $item num text
        if {!$first} { $w insert $idx "\n" $tags }
        # A plain if, not expr's ?: - expr would coerce "3." to the float 3.0.
        if {$num eq ""} { set marker "•" } else { set marker "$num." }
        $w insert $idx "$marker\t" $tags
        ::tkdown::runs $w $idx $text $tags
        set first 0
    }
}

# ---- the grid ------------------------------------------------------------
#
# A table is one embedded window: a frame of gridded text cells that wrap
# their words, so a table wider than the pane folds its long cells instead
# of running off the edge. A cell is a text widget because one cell can mix
# faces (bold, `code`). The window builds itself only when the text first
# shows it (-create), so a long document costs no widgets until it is read;
# everything search and spotlight need is recorded at emit time instead:
# the payload, the cells' text as the reader sees it, and a mark on the
# window character. Per table the registry keeps
#   mark frame payload base flat lit fbtok cells
# base being the baseTags the table was painted under and lit whether it
# is the spotlit table.

# Paint a parsed GFM table {align rows} at idx: the window character under
# td-tblwin (its margins, raised over the base tags' own) and baseTags (so a
# host's fold or elide tag reaches the table too), the left-gravity mark
# tbl#m<N> on it, then a blank line under baseTags. A table met mid-line
# starts a line of its own.
proc ::tkdown::emit_table {w idx payload baseTags} {
    variable widgets
    set id [dict get $widgets $w nextid]
    incr id
    dict set widgets $w nextid $id
    set at [$w index $idx]
    if {[$w compare $at == end]} { set at [$w index end-1c] }
    if {[$w compare $at != "$at linestart"]} {
        $w insert $idx "\n" $baseTags
        set at [$w index "$at +1c"]
    }
    $w window create $idx -create [list ::tkdown::table_realize $w $id] \
        -align top -pady 2 -stretch 0
    foreach tag [concat $baseTags [list td-tblwin]] { $w tag add $tag $at }
    $w tag raise td-tblwin
    $w mark set tbl#m$id $at
    $w mark gravity tbl#m$id left
    $w insert $idx "\n\n" $baseTags
    set flat [lmap row [dict get $payload rows] {
        lmap cell $row {
            set s ""
            foreach run [::tkdown::parse_inline $cell] { append s [lindex $run 1] }
            set s
        }
    }]
    dict set widgets $w tables $id [dict create mark tbl#m$id frame $w.tbl$id \
        payload $payload base $baseTags flat $flat lit 0 fbtok "" cells {}]
}

# The window's -create: build table id's frame and return its path, or ""
# for a table the registry no longer holds. The frame's background is the
# gridline colour, showing through the one-pixel pads around each cell.
proc ::tkdown::table_realize {w id} {
    variable widgets
    if {![dict exists $widgets $w tables $id]} { return "" }
    set t [dict get $widgets $w tables $id]
    set f [dict get $t frame]
    if {[winfo exists $f]} { return $f }
    set fonts [dict get $widgets $w fonts]
    frame $f -borderwidth 0 -highlightthickness 0
    set align [dict get $t payload align]
    set ncol [llength $align]
    set cells [list]
    set r 0
    foreach row [dict get $t payload rows] {
        for {set j 0} {$j < $ncol} {incr j} {
            set c $f.c${r}x$j
            text $c -wrap word -width 1 -height 1 -borderwidth 0 \
                -highlightthickness 0 -padx 4 -pady 2 -takefocus 0 \
                -font [dict get $fonts body]
            ::tkdown::table_fill_cell $c $fonts [lindex $row $j] \
                [expr {$r == 0}] [lindex $align $j]
            grid $c -row $r -column $j -sticky nsew -padx 1 -pady 1
            # A cell's height follows its width: whenever grid hands it one
            # (first map, a re-fit, a font change), -height is resynced to
            # the wrapped line count.
            bind $c <Configure> [list ::tkdown::table_cell_height $c]
            lappend cells $c
        }
        incr r
    }
    ttk::button $f.copy -style [::tkdown::copy_style $w] -text "⧉" -width 2 \
        -takefocus 0 -cursor hand2 -command [list ::tkdown::table_copy $w $id]
    foreach x [concat [list $f $f.copy] $cells] {
        bindtags $x [linsert [bindtags $x] 1 tkdown.grid$w]
    }
    bind $f <Destroy> [list ::tkdown::table_destroyed $w $id %W]
    dict set widgets $w tables $id cells $cells
    ::tkdown::table_paint $w $id
    after idle [list ::tkdown::table_fit $w $id]
    return $f
}

# Fill one cell from its markdown: the inline runs under per-cell face
# tags, a header cell bold throughout (hb is configured last, so it
# outranks the span faces), an aligned column justified by al.
proc ::tkdown::table_fill_cell {c fonts cell header align} {
    foreach {tg k} {b bold i italic bi bolditalic cd mono hb bold} {
        $c tag configure $tg -font [dict get $fonts $k]
    }
    if {$align ne "left"} { $c tag configure al -justify $align }
    foreach run [::tkdown::parse_inline $cell] {
        lassign $run style chunk
        switch -- $style {
            code       { set tags cd }
            bold       { set tags b }
            italic     { set tags i }
            bolditalic { set tags bi }
            default    { set tags {} }
        }
        $c insert end $chunk $tags
    }
    if {$header} { $c tag add hb 1.0 end }
    if {$align ne "left"} { $c tag add al 1.0 end }
    $c configure -state disabled
}

# Colour a built grid from the pane as it stands: the frame in the gridline
# (or spotlight) colour, each cell in the pane's background and cursor and
# the ink of the table's base tags.
proc ::tkdown::table_paint {w id} {
    variable widgets
    set t [dict get $widgets $w tables $id]
    set f [dict get $t frame]
    set bg [::tkdown::grid_colour $w]
    if {[dict get $t lit]} {
        set spot [::tkdown::tag_ink $w td-spot -background]
        if {$spot ne ""} { set bg $spot }
    }
    $f configure -background $bg
    set fg [$w cget -foreground]
    foreach tag [dict get $t base] {
        set ink [::tkdown::tag_ink $w $tag -foreground]
        if {$ink ne ""} { set fg $ink; break }
    }
    foreach c [dict get $t cells] {
        $c configure -background [$w cget -background] -foreground $fg \
            -cursor [$w cget -cursor]
    }
}

# A tag option's value on w, or "" when the host has not configured it.
proc ::tkdown::tag_ink {w tag opt} {
    if {[catch {$w tag cget $tag $opt} v]} { return "" }
    return $v
}

proc ::tkdown::grid_colour {w} {
    set c [::tkdown::tag_ink $w td-grid -background]
    if {$c eq ""} { set c [$w cget -foreground] }
    return $c
}

# The copy button's style: -copystyle while it names a style ttk knows,
# else plain TButton, so a host that styled nothing still gets a button.
proc ::tkdown::copy_style {w} {
    variable widgets
    set s [dict get $widgets $w copystyle]
    if {[catch {ttk::style layout $s}]} { set s TButton }
    return $s
}

# The table id behind a window of w's grids (frame, cell or button), or "".
proc ::tkdown::table_of {w x} {
    set pre $w.tbl
    if {[string first $pre $x] != 0} { return "" }
    if {![regexp {^(\d+)(\.|$)} [string range $x [string length $pre] end] \
            -> id]} { return "" }
    return $id
}

# Show a table's copy button at its top-right while the pointer is over it.
# Crossing from the frame into a cell fires <Leave> on the frame, so the
# hide waits for idle and keeps the button while the pointer is anywhere
# inside the frame.
proc ::tkdown::table_hover {w x} {
    set id [::tkdown::table_of $w $x]
    if {$id eq ""} return
    set f $w.tbl$id
    if {![winfo exists $f.copy]} return
    place $f.copy -in $f -relx 1.0 -x -2 -y 2 -anchor ne
    raise $f.copy
}

proc ::tkdown::table_hover_check {w x} {
    set id [::tkdown::table_of $w $x]
    if {$id eq ""} return
    set f $w.tbl$id
    if {![winfo exists $f.copy]} return
    set at [winfo containing {*}[winfo pointerxy $f]]
    if {$at eq $f || [string first $f. $at] == 0} return
    place forget $f.copy
}

# The copy button's action: the table as GFM onto the clipboard, the
# embedded window's text being out of reach of a drag-selection. The button
# shows ✓ for 700 ms.
proc ::tkdown::table_copy {w id} {
    variable widgets
    if {![dict exists $widgets $w tables $id]} return
    set t [dict get $widgets $w tables $id]
    clipboard clear -displayof $w
    clipboard append -displayof $w -- \
        [::tkdown::table_to_markdown [dict get $t payload]]
    set f [dict get $t frame]
    if {![winfo exists $f.copy]} return
    after cancel [dict get $t fbtok]
    $f.copy configure -text "✓"
    dict set widgets $w tables $id fbtok \
        [after 700 [list ::tkdown::table_copy_reset $w $id]]
}

proc ::tkdown::table_copy_reset {w id} {
    variable widgets
    if {![dict exists $widgets $w tables $id]} return
    dict set widgets $w tables $id fbtok ""
    set f [dict get $widgets $w tables $id frame]
    if {[winfo exists $f.copy]} { $f.copy configure -text "⧉" }
}

# Size a built grid's columns to the pane. avail is the pane's inner width
# less both margins and, per column, the two gridline pixels and the
# cell's own padding; table_colwidths turns the cells' measured words into
# column widths, pinned as grid minsizes. The cells' <Configure> bindings
# turn the new widths into wrapped heights. Words are measured afresh on
# every fit, so a font change re-fits with nothing else to do.
proc ::tkdown::table_fit {w id} {
    variable widgets
    if {![dict exists $widgets $w tables $id]} return
    set t [dict get $widgets $w tables $id]
    set f [dict get $t frame]
    if {![winfo exists $f]} return
    if {[winfo width $w] <= 1} return
    set fonts [dict get $widgets $w fonts]
    set ncol [llength [dict get $t payload align]]
    lassign [dict get $widgets $w margin] l r
    set inset [expr {2 * ([winfo pixels $w [$w cget -borderwidth]] \
        + [winfo pixels $w [$w cget -highlightthickness]] \
        + [winfo pixels $w [$w cget -padx]])}]
    set avail [expr {[winfo width $w] - $inset - $l - $r - $ncol * 10}]
    if {$avail < $ncol} { set avail $ncol }
    set rows [list]
    set header 1
    foreach row [dict get $t payload rows] {
        lappend rows [lmap cell $row { ::tkdown::cell_tokens $fonts $cell $header }]
        set header 0
    }
    set body [dict get $fonts body]
    set widths [::tkdown::table_colwidths $rows $avail \
        [font measure $body "0"] [font measure $body " "]]
    set j 0
    foreach cw $widths {
        grid columnconfigure $f $j -minsize [expr {$cw + 10}] -weight 0
        incr j
    }
}

# The pixel widths of one cell's words, each run measured in the face it
# paints in (a header cell is bold throughout). A word split across runs,
# as in a**b**, is one token whose width is the sum of its pieces.
proc ::tkdown::cell_tokens {fonts cell header} {
    set out [list]
    set cur -1
    foreach run [::tkdown::parse_inline $cell] {
        lassign $run style chunk
        if {$header} {
            set f [dict get $fonts bold]
        } else {
            switch -- $style {
                code       { set f [dict get $fonts mono] }
                bold       { set f [dict get $fonts bold] }
                italic     { set f [dict get $fonts italic] }
                bolditalic { set f [dict get $fonts bolditalic] }
                default    { set f [dict get $fonts body] }
            }
        }
        foreach piece [regexp -all -inline {\s+|\S+} $chunk] {
            if {[string is space $piece]} {
                if {$cur >= 0} { lappend out $cur; set cur -1 }
            } elseif {$cur < 0} {
                set cur [font measure $f $piece]
            } else {
                incr cur [font measure $f $piece]
            }
        }
    }
    if {$cur >= 0} { lappend out $cur }
    return $out
}

# One cell's <Configure>: size it to its wrapped display-line count at the
# width grid just gave it. Setting -height resizes only the cell's row, and
# the height-only Configure that follows measures the same count, so the
# chain ends there.
proc ::tkdown::table_cell_height {c} {
    if {![winfo exists $c]} return
    set dl [$c count -update -displaylines 1.0 end]
    if {$dl < 1} { set dl 1 }
    if {[$c cget -height] != $dl} { $c configure -height $dl }
}

# A grid's <Destroy>, whether by forget or by its window character being
# deleted: the table leaves the registry. Its mark stays until forget.
proc ::tkdown::table_destroyed {w id x} {
    variable widgets
    if {![dict exists $widgets $w tables $id]} return
    if {[dict get $widgets $w tables $id frame] ne $x} return
    after cancel [dict get $widgets $w tables $id fbtok]
    dict unset widgets $w tables $id
    if {[dict get $widgets $w spot] eq $id} { dict set widgets $w spot "" }
}

# Drop the tables whose mark no longer sits on their window character: the
# text holding them was deleted before the grid was ever built, so no
# <Destroy> came to say so.
proc ::tkdown::table_prune {w} {
    variable widgets
    dict for {id t} [dict get $widgets $w tables] {
        set m [dict get $t mark]
        if {![catch {$w dump -window $m} d]} {
            if {[llength $d] == 3 && [lindex $d 1] in [list "" [dict get $t frame]]} {
                continue
            }
            $w mark unset $m
        }
        after cancel [dict get $t fbtok]
        destroy [dict get $t frame]
        dict unset widgets $w tables $id
        if {[dict get $widgets $w spot] eq $id} { dict set widgets $w spot "" }
    }
}

# Search the tables' text, which a `$w search` cannot see inside an
# embedded window. One hit per table, in document order: {mark excerpt},
# the excerpt being the first matching cell's text as the reader sees it.
proc ::tkdown::table_scan {w needle nocase} {
    variable widgets
    if {![dict exists $widgets $w] || $needle eq ""} { return {} }
    ::tkdown::table_prune $w
    if {$nocase} { set needle [string tolower $needle] }
    set out [list]
    dict for {id t} [dict get $widgets $w tables] {
        set hit ""
        foreach cell [concat {*}[dict get $t flat]] {
            set hay [expr {$nocase ? [string tolower $cell] : $cell}]
            if {[string first $needle $hay] >= 0} { set hit $cell; break }
        }
        if {$hit ne ""} { lappend out [list [dict get $t mark] $hit] }
    }
    return [lsort -command [list ::tkdown::mark_order $w] $out]
}

proc ::tkdown::mark_order {w a b} {
    set a [lindex $a 0]
    set b [lindex $b 0]
    if {[$w compare $a < $b]} { return -1 }
    if {[$w compare $a > $b]} { return 1 }
    return 0
}

# Light the table whose mark sits at idx and put out the one lit before;
# any other idx, "" included, only puts it out. A lit grid's frame takes
# td-spot's background, so the gridlines and border read as the hit. The
# flag is set before the grid exists, so a reveal that scrolls a table into
# view for the first time builds it lit.
proc ::tkdown::table_spotlight {w idx} {
    variable widgets
    if {![dict exists $widgets $w]} return
    set target ""
    if {$idx ne ""} {
        dict for {id t} [dict get $widgets $w tables] {
            if {![catch {$w compare [dict get $t mark] == $idx} same] && $same} {
                set target $id
                break
            }
        }
    }
    set prev [dict get $widgets $w spot]
    if {$prev ne "" && $prev ne $target && [dict exists $widgets $w tables $prev]} {
        dict set widgets $w tables $prev lit 0
        if {[winfo exists [dict get $widgets $w tables $prev frame]]} {
            ::tkdown::table_paint $w $prev
        }
    }
    dict set widgets $w spot $target
    if {$target eq ""} return
    dict set widgets $w tables $target lit 1
    if {[winfo exists [dict get $widgets $w tables $target frame]]} {
        ::tkdown::table_paint $w $target
    }
}
