#!/usr/bin/env tclsh9.0
package require Tcl 9
set ROOT [file dirname [file dirname [file dirname [file normalize [info script]]]]]
foreach md [glob -directory [file join $ROOT modules] -type d *] { ::tcl::tm::path add $md }
package prefer latest
package require tkdown

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
proc pi {s} { return [::tkdown::parse_inline $s] }

# ---- parse_inline: prose into styled inline runs ---------------------------
# Each style, markers stripped.
check inline_italic        {{italic x}}           [pi {*x*}]
check inline_bold          {{bold x}}             [pi {**x**}]
check inline_bolditalic    {{bolditalic x}}       [pi {***x***}]
check inline_code          {{code x}}             [pi {`x`}]
check inline_plain         {{plain {hello world}}} [pi {hello world}]

# Code spans win over emphasis: asterisks inside backticks stay literal.
check code_over_glob       {{code **/*.tcl}}      [pi {`**/*.tcl`}]
check code_over_bold       {{code **bold**}}      [pi {`**bold**`}]

# Flanking guards reject non-emphasis asterisks.
check flank_mult           {{plain {3 * 4}}}      [pi {3 * 4}]
check flank_bullet         {{plain {* item}}}     [pi {* item}]
check flank_spaced         {{plain {a * b}}}      [pi {a * b}]

# No matching closer: markers stay literal.
check unclosed_glob        {{plain **/*.tcl}}     [pi {**/*.tcl}]
check unclosed_backtick    {{plain {use the ` key}}} [pi {use the ` key}]

# Backslash escapes.
check escape_asterisk      {{plain *literal*}}    [pi {\*literal\*}]
check escape_backtick      {{plain `}}            [pi {\`}]
check escape_backslash     {{plain \\}}           [pi {\\}]

# Underscores stay literal (asterisk-only emphasis).
check snake_case_plain     {{plain {my_var __init__ tool_use_id}}} \
    [pi {my_var __init__ tool_use_id}]

# Mixed run: plain coalesced, code and bold in document order.
check mixed_run \
    {{plain {see }} {code foo} {plain { and }} {bold bar}} \
    [pi {see `foo` and **bar**}]

# bolditalic embedded mid-prose.
check bolditalic_embedded \
    {{plain {a }} {bolditalic b} {plain { c}}} \
    [pi {a ***b*** c}]

# ---- segment_blockquotes: split a body into ordered {kind text} segments,
# de-quoting one leading "> "/">" per blockquote line, strict blank split.
check seg_plain      {{normal hello}} \
    [::tkdown::segment_blockquotes "hello"]
check seg_pure_quote {{quote {To: a@b
body}}} \
    [::tkdown::segment_blockquotes "> To: a@b\n> body"]
check seg_mixed      {{normal intro:} {quote {line one
line two}} {normal outro}} \
    [::tkdown::segment_blockquotes "intro:\n> line one\n> line two\noutro"]
check seg_bare_gt    {{quote {has space
no space}}} \
    [::tkdown::segment_blockquotes "> has space\n>no space"]
check seg_blank_split {{quote first} {normal {}} {quote second}} \
    [::tkdown::segment_blockquotes "> first\n\n> second"]

# ---- segment_tables: split a prose run into {normal text} / {table payload}
# segments, payload = {align <per-col> rows <header-then-body>}. Expected
# values are built the same way the proc builds them (list + dict create), so
# a dict-ordering quirk can never make a correct result read as a failure.
check tbl_basic \
    [list [list table [dict create align {left left} rows {{H1 H2} {a b}}]]] \
    [::tkdown::segment_tables "| H1 | H2 |\n| --- | --- |\n| a | b |"]
check tbl_align \
    [list [list table [dict create align {left right center} \
        rows {{L R C} {1 2 3}}]]] \
    [::tkdown::segment_tables "| L | R | C |\n| :-- | --: | :-: |\n| 1 | 2 | 3 |"]
check tbl_unbounded \
    [list [list table [dict create align {left left} rows {{a b} {1 2}}]]] \
    [::tkdown::segment_tables "a | b\n- | -\n1 | 2"]
check tbl_escape \
    [list [list table [dict create align {left left} \
        rows [list {H1 H2} [list "a | b" c]]]]] \
    [::tkdown::segment_tables "| H1 | H2 |\n| - | - |\n| a \\| b | c |"]
check tbl_ragged \
    [list [list table [dict create align {left left left} \
        rows {{H1 H2 H3} {a b {}} {c d e}}]]] \
    [::tkdown::segment_tables \
        "| H1 | H2 | H3 |\n| - | - | - |\n| a | b |\n| c | d | e | f |"]
check tbl_header_only \
    [list [list table [dict create align {left left} rows {{H1 H2}}]]] \
    [::tkdown::segment_tables "| H1 | H2 |\n| - | - |"]
check tbl_setext \
    [list [list normal "Heading\n---\nbody"]] \
    [::tkdown::segment_tables "Heading\n---\nbody"]
check tbl_pipe_no_delim \
    [list [list normal "| not a table |\njust text"]] \
    [::tkdown::segment_tables "| not a table |\njust text"]
check tbl_interleave \
    [list [list normal "intro\n"] \
        [list table [dict create align {left left} rows {{H1 H2} {a b}}]] \
        [list normal "\noutro"]] \
    [::tkdown::segment_tables \
        "intro\n\n| H1 | H2 |\n| - | - |\n| a | b |\n\noutro"]

# ---- segment_lists: split a normal run into {normal text} / {list items}
# segments; each item is {num text}, num "" for a bullet or the digits for an
# ordered item, flat only (an indented or nested marker stays literal).
check list_bullet \
    [list [list list {{{} apples} {{} pears}}]] \
    [::tkdown::segment_lists "- apples\n- pears"]
check list_star \
    [list [list list {{{} one} {{} two}}]] \
    [::tkdown::segment_lists "* one\n* two"]
check list_numbered \
    [list [list list {{1 first} {2 second} {3 third}}]] \
    [::tkdown::segment_lists "1. first\n2. second\n3. third"]
check list_numbering_kept \
    [list [list list {{2 two} {3 three}}]] \
    [::tkdown::segment_lists "2. two\n3. three"]
check list_mixed_markers \
    [list [list list {{{} bul} {1 ord}}]] \
    [::tkdown::segment_lists "- bul\n1. ord"]
check list_prose_around \
    [list [list normal intro] [list list {{{} a} {{} b}}] [list normal outro]] \
    [::tkdown::segment_lists "intro\n- a\n- b\noutro"]
check list_midline_literal \
    [list [list normal "use the - dash key\nrun 3 * 4 now"]] \
    [::tkdown::segment_lists "use the - dash key\nrun 3 * 4 now"]
check list_indented_literal \
    [list [list normal "  - nested\n    * deeper"]] \
    [::tkdown::segment_lists "  - nested\n    * deeper"]
check list_version_literal \
    [list [list normal "tcl 9.0 and 1.2.3 stay text"]] \
    [::tkdown::segment_lists "tcl 9.0 and 1.2.3 stay text"]
check list_none \
    [list [list normal "just a paragraph\nof two lines"]] \
    [::tkdown::segment_lists "just a paragraph\nof two lines"]

# ---- table_to_markdown: a payload back to GFM text that segment_tables reads
# back to the same payload.
set payload [dict create align {left center right} rows {{a b c} {d {e | f} g}}]
check md_delim_and_escape "| a | b | c |\n| --- | :---: | ---: |\n| d | e \\| f | g |" \
    [::tkdown::table_to_markdown $payload]
check md_round_trip [list [list table $payload]] \
    [::tkdown::segment_tables [::tkdown::table_to_markdown $payload]]

# ---- table_colwidths: column widths for a table whose cells wrap. Shapes are
# in character units (em 1, space 1). The cost is recomputed here from its
# definition rather than read from the module, so a module whose own cost
# drifted from the definition fails the property instead of agreeing with
# itself.

# Lines of one cell at width w under greedy word wrap; a token wider than w
# starts a line and breaks every w, each break a line and, with pen, one more.
proc ref_lines {cell w space pen} {
    set lines 1
    set used 0
    set empty 1
    foreach t $cell {
        if {$w > 0 && $t > $w} {
            if {!$empty} { incr lines }
            set rest $t
            while {$rest > $w} {
                set rest [expr {$rest - $w}]
                incr lines [expr {$pen ? 2 : 1}]
            }
            set used $rest
        } elseif {$empty} {
            set used $t
        } elseif {$used + $space + $t <= $w} {
            set used [expr {$used + $space + $t}]
        } else {
            incr lines
            set used $t
        }
        set empty 0
    }
    return $lines
}
# Each row as tall as its tallest cell, summed; pen 0 gives the height.
proc ref_cost {rows widths space {pen 1}} {
    set total 0
    foreach row $rows {
        set tallest 1
        foreach cell $row w $widths {
            set tallest [expr {max($tallest, [ref_lines $cell $w $space $pen])}]
        }
        incr total $tallest
    }
    return $total
}
proc ref_maxs {rows space} {
    set maxs [lrepeat [llength [lindex $rows 0]] 0]
    foreach row $rows {
        set j 0
        foreach cell $row {
            set full [expr {[tcl::mathop::+ 0 {*}$cell]
                + max(0, [llength $cell] - 1) * $space}]
            lset maxs $j [expr {max([lindex $maxs $j], $full)}]
            incr j
        }
    }
    return $maxs
}
proc ref_floors {rows avail em} {
    set ncol [llength [lindex $rows 0]]
    set cap [expr {min(8 * $em, $avail / $ncol)}]
    set floors [lrepeat $ncol 0]
    foreach row $rows {
        set j 0
        foreach cell $row {
            foreach t $cell {
                lset floors $j [expr {max([lindex $floors $j], min($t, $cap))}]
            }
            incr j
        }
    }
    return $floors
}
# The proportional shrink: max-contents scaled to avail, clamped
# into [floor, max], the remainder given to columns with room, first first.
proc ref_prop {rows avail em space} {
    set maxs [ref_maxs $rows $space]
    set floors [ref_floors $rows $avail $em]
    set summax [tcl::mathop::+ {*}$maxs]
    set out [lmap hi $maxs lo $floors {
        expr {min(max($hi * $avail / $summax, $lo), $hi)}
    }]
    set j 0
    while {[set left [expr {$avail - [tcl::mathop::+ {*}$out]}]] != 0} {
        set cw [lindex $out $j]
        if {$left > 0} {
            lset out $j [expr {min([lindex $maxs $j], $cw + $left)}]
        } else {
            lset out $j [expr {max([lindex $floors $j], $cw + $left)}]
        }
        incr j
    }
    return $out
}
# Every way a result can break the contract, as a list of faults.
proc colwidths_faults {rows avail em space widths} {
    set faults [list]
    set maxs [ref_maxs $rows $space]
    if {[tcl::mathop::+ {*}$maxs] <= $avail} {
        if {$widths ne $maxs} { lappend faults "fits but widths $widths not $maxs" }
        return $faults
    }
    if {[tcl::mathop::+ {*}$widths] != $avail} {
        lappend faults "widths $widths do not sum to $avail"
    }
    foreach w $widths lo [ref_floors $rows $avail $em] {
        if {$w < $lo} { lappend faults "width $w under its floor $lo" }
    }
    set c [ref_cost $rows $widths $space]
    set cp [ref_cost $rows [ref_prop $rows $avail $em $space] $space]
    if {$c > $cp} { lappend faults "cost $c above the proportional seed's $cp" }
    return $faults
}
proc cw {rows avail} { return [::tkdown::table_colwidths $rows $avail 1 1] }

# The two ends of the contract: max-contents when they fit, floors when even
# the floors fill avail (here 8 ems caps the long tokens).
check cw_fits {3 5} [cw {{{3} {2 2}} {{1} {5}}} 20]
check cw_floors {8 8} [cw {{{20} {30}} {{4} {4 4 4}}} 16]

# Case 1: a short label, a date, and two prose columns; the prose columns
# take what the fixed ones leave.
set case1 {
    {5 4 8 7}
    {{5 1} 10 {7 4 2 1 5} {6 4 4}}
    {{5 1} 10 {7 5 9 5 9 4} {5 5 4 3 3 3 2 1 6}}
    {{5 1} 10 {6 2 3 10 5 4} {6 4 4}}
    {{5 1} 10 {9 6 1 5 4} {5 5 4}}
    {{5 1} 10 {5 5 6 6 4 8} {4 6 5}}
    {{5 1} 10 {5 4 2 6 5 4} {6 4 4}}
    {{5 1} 10 {3 1 5 6 2 3 6} {4 8}}
    {{5 1} 10 {5 4} {8 4}}
    {{5 1} 10 {6 5 1} {6 4 4}}
    {{5 1} 10 {5 4} {6 4 4}}
    {{5 1} 10 {3 1 5} {8 4}}
    {{5 1} 10 {7 4 3 8 8 10} {8 4 10}}
}
set w [cw $case1 100]
check cw_case1_sum 100 [tcl::mathop::+ {*}$w]
check cw_case1_height 1 [expr {[ref_cost $case1 $w 1 0] <= 15}]
check cw_case1_contract {} [colwidths_faults $case1 100 1 1 $w]
set case1_height [ref_cost $case1 $w 1 0]

# Seeded prose: n characters as tokens of 2 to 9.
proc words {n} {
    set toks [list]
    set left $n
    while {$left > 0} {
        set t [expr {min($left, 2 + int(rand() * 8))}]
        lappend toks $t
        set left [expr {$left - $t - 1}]
    }
    return $toks
}

# Case 2: a fixed-width key beside one long prose column.
expr {srand(11)}
set case2 [list {{6} {6}}]
for {set r 0} {$r < 4} {incr r} {
    set toks [list]
    set n [expr {12 + int(rand() * 34)}]
    for {set k 0} {$k < $n} {incr k} { lappend toks [expr {2 + int(rand() * 8)}] }
    lappend case2 [list {9} $toks]
}

# Case 3: a small integer, three prose columns, and a last column that is
# a digit, sometimes followed by a run of words.
expr {srand(7)}
set case3 {{{1} {5 6} {5 6} {5 6} {5}}}
for {set r 0} {$r < 17} {incr r} {
    set c5 [expr {rand() < 0.3 ? [concat 1 [words 40]] : {1}}]
    lappend case3 [list [list [expr {1 + int(rand() * 2)}]] \
        [words [expr {15 + int(rand() * 120)}]] \
        [words [expr {15 + int(rand() * 150)}]] \
        [words [expr {40 + int(rand() * 160)}]] $c5]
}
foreach name {case2 case3} {
    foreach avail {100 70} {
        set w [cw [set $name] $avail]
        check cw_${name}_$avail {} [colwidths_faults [set $name] $avail 1 1 $w]
        if {$avail == 100} { set ${name}_height [ref_cost [set $name] $w 1 0] }
    }
}
puts "heights at avail 100: case1 $case1_height case2 $case2_height case3 $case3_height"

# The corpus: every table at a pane of 100 and of 70 characters, less a
# two-character gutter per column.
set f [open [file join [file dirname [info script]] table-shapes.txt]]
set ntab 0
set faulted [list]
set t0 [clock milliseconds]
while {[gets $f line] >= 0} {
    if {[string match #* $line]} continue
    set rows [lindex $line 0]
    set ncol [llength [lindex $rows 0]]
    if {$ncol == 0} continue
    set ragged 0
    foreach row $rows { if {[llength $row] != $ncol} { set ragged 1 } }
    if {$ragged} continue
    foreach pane {100 70} {
        set avail [expr {$pane - 2 * $ncol}]
        if {$avail < $ncol} continue
        incr ntab
        set w [cw $rows $avail]
        set faults [colwidths_faults $rows $avail 1 1 $w]
        if {[llength $faults]} { lappend faulted [list $pane $rows $faults] }
    }
}
close $f
set ms [expr {[clock milliseconds] - $t0}]
puts "corpus: $ntab tables in $ms ms"
foreach x [lrange $faulted 0 4] { puts "  $x" }
check cw_corpus_faults 0 [llength $faulted]
check cw_corpus_under_10s 1 [expr {$ms < 10000}]

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
