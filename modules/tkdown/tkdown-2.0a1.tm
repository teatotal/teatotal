package require Tcl 9
package provide tkdown 2.0a1

namespace eval ::tkdown {
    namespace export parse_inline segment_tables segment_code_fences \
        segment_blockquotes segment_lists table_to_markdown table_colwidths \
        tags runs prose body refit forget
    # Emit state, one entry per registered widget:
    # widget path -> {fonts <dict> tables <id -> payload> nextid <int>}
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
# keys are kept but nothing draws with them.
# Registration opens the widget's table registry (the parsed payloads behind
# refit); the registry entry dies with the widget.
proc ::tkdown::tags {w fonts} {
    variable widgets
    foreach k {body bold italic bolditalic mono} {
        if {![dict exists $fonts $k]} {
            error "tkdown: fonts dict missing \"$k\""
        }
    }
    dict set widgets $w [dict create fonts $fonts tables [dict create] nextid 0]
    # Later-configured tags win on -font where they stack: headings first so
    # emphasis spans inside a heading still restyle, the table header face
    # last so a header cell reads bold over any span it carries.
    foreach lvl {h1 h2 h3} {
        set f [expr {[dict exists $fonts $lvl]
            ? [dict get $fonts $lvl] : [dict get $fonts bold]}]
        $w tag configure td-$lvl -font $f
    }
    $w tag configure td-bold       -font [dict get $fonts bold]
    $w tag configure td-italic     -font [dict get $fonts italic]
    $w tag configure td-bolditalic -font [dict get $fonts bolditalic]
    $w tag configure td-code       -font [dict get $fonts mono]
    $w tag configure td-head       -font [dict get $fonts bold]
    # td-list carries the list hanging indent and nothing else (geometry-only,
    # colour stays the host's). lmargin1 10 is the table's own left margin;
    # lmargin2 30 sets item text (and any wrapped continuation) a marker-width
    # in from it, and the tab stop at 30 lands the text after the marker there.
    $w tag configure td-list -lmargin1 10 -lmargin2 30 -tabs 30
    bind $w <Destroy> +[list ::tkdown::unregister $w]
}

proc ::tkdown::unregister {w} {
    variable widgets
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
# and rendered piecewise, each table as tab-aligned columns under its own
# td-tbl<N> tag.
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

# Recompute -tabs for every rendered table on w under the current fonts.
# Stops depend on the font, not the pane width, so a resize recomputes the
# same values; the live path is a reading-font change.
proc ::tkdown::refit {w} {
    variable widgets
    if {![dict exists $widgets $w]} return
    dict for {id payload} [dict get $widgets $w tables] {
        set tag td-tbl$id
        if {![llength [$w tag ranges $tag]]} continue
        $w tag configure $tag -tabs [::tkdown::table_tabs $w $payload]
    }
}

# Drop w's rendered tables: the registry payloads and the td-tbl<N> tags,
# which survive a `delete 1.0 end` as configured-but-empty tags and would
# pile up across reloads. Registration survives; call before a re-render.
proc ::tkdown::forget {w} {
    variable widgets
    if {![dict exists $widgets $w]} return
    dict set widgets $w tables [dict create]
    dict set widgets $w nextid 0
    foreach tag [$w tag names] {
        if {[string match td-tbl* $tag]} { $w tag delete $tag }
    }
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

# Render a parsed GFM table {align rows} as tab-aligned columns. Each table
# gets its own tag td-tbl<N> carrying the computed -tabs (so two tables never
# share column geometry) plus -wrap none (a row wider than the pane clips at
# the right edge rather than wrapping and breaking the columns). Cells render
# through runs so inline markdown inside a cell still styles; header cells
# also carry td-head for bold. The payload is kept in the widget's registry
# so a font change can recompute the stops (refit).
proc ::tkdown::emit_table {w idx payload baseTags} {
    variable widgets
    set id [dict get $widgets $w nextid]
    incr id
    dict set widgets $w nextid $id
    set tag td-tbl$id
    set ncol [llength [dict get $payload align]]
    $w tag configure $tag -wrap none -lmargin1 10 -lmargin2 10 \
        -spacing1 1 -spacing3 1 -tabs [::tkdown::table_tabs $w $payload]
    set rowtags [concat $baseTags [list $tag]]
    set first 1
    foreach row [dict get $payload rows] {
        for {set j 0} {$j < $ncol} {incr j} {
            if {$j > 0} { $w insert $idx "\t" $rowtags }
            set base $rowtags
            if {$first} { lappend base td-head }
            ::tkdown::runs $w $idx [lindex $row $j] $base
        }
        $w insert $idx "\n" $rowtags
        set first 0
    }
    $w insert $idx "\n" $baseTags
    dict set widgets $w tables $id $payload
}

# The -tabs spec for a table: N-1 stops (column 0 anchors at the left margin,
# so a delimiter asking right/center on column 0 falls back to left). A
# column's stop sits at its content's left edge (left), right edge (right) or
# centre (center); column content widths are the per-column max over all rows,
# the header measured bold. The gutter and stops scale with the registered
# fonts, so the table re-fits when the font changes. Floored by sane_tabs
# because Tk rejects a non-increasing or non-positive stop.
proc ::tkdown::table_tabs {w payload} {
    variable widgets
    set fonts [dict get $widgets $w fonts]
    set align [dict get $payload align]
    set ncol [llength $align]
    # Readable defaults, no deeper constraint: a 10 px left margin and a
    # gutter two body-font digits wide, which scales the column gap with
    # the font where a fixed pixel count would not.
    set lm 10
    set gut [font measure [dict get $fonts body] "00"]
    set cw [lrepeat $ncol 0]
    set first 1
    foreach row [dict get $payload rows] {
        for {set j 0} {$j < $ncol} {incr j} {
            set width [::tkdown::cell_width $fonts [lindex $row $j] $first]
            if {$width > [lindex $cw $j]} { lset cw $j $width }
        }
        set first 0
    }
    set stops [list]
    set x $lm
    for {set j 0} {$j < $ncol} {incr j} {
        if {$j > 0} {
            set a [lindex $align $j]
            switch -- $a {
                right  { set pos [expr {$x + [lindex $cw $j]}] }
                center { set pos [expr {$x + [lindex $cw $j] / 2}] }
                default { set pos $x }
            }
            lappend stops $pos $a
        }
        set x [expr {$x + [lindex $cw $j] + $gut}]
    }
    return [::tkdown::sane_tabs $stops]
}

# The rendered pixel width of one cell, summing each inline run in the font
# it will paint in (so a bold or `code` span is measured at its real width,
# not under-measured in the base face). bold widens the plain runs, for a
# header cell.
proc ::tkdown::cell_width {fonts text bold} {
    set w 0
    foreach run [::tkdown::parse_inline $text] {
        lassign $run style chunk
        if {$bold} {
            # A header cell paints bold throughout: td-head outranks every
            # span face where they stack, so measuring must too.
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
        incr w [font measure $f $chunk]
    }
    return $w
}

# Coerce a {pos align ...} tab spec to strictly increasing positive stops,
# which Tk requires. Guards the degenerate column geometry a too-narrow width
# (a build-time placeholder, or high DPI) can produce.
proc ::tkdown::sane_tabs {tabs} {
    set out [list]
    set prev 0
    foreach {x align} $tabs {
        if {$x <= $prev} { set x [expr {$prev + 1}] }
        lappend out $x $align
        set prev $x
    }
    return $out
}
