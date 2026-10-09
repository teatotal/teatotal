#!/usr/bin/env tclsh9.0
package require Tcl 9
set ROOT [file dirname [file dirname [file dirname [file normalize [info script]]]]]
foreach md [glob -directory [file join $ROOT modules] -type d *] { ::tcl::tm::path add $md }
package require tkdown 2.1

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
check escape_dollar        {{plain {costs $18.34}}} [pi {costs \$18.34}]
check escape_underscore    {{plain _x_}}          [pi {\_x\_}]
check escape_hash          {{plain #}}            [pi {\#}]
check escape_path_kept     [list [list plain {C:\Users\me}]] [pi {C:\Users\me}]
check escape_trailing      [list [list plain "end\\"]] [pi "end\\"]
check escape_not_link      {{plain {[not a link](x)}}} [pi {\[not a link](x)}]
check escape_not_code      {{plain `a`}}      [pi {\`a\`}]

# A code span is literal, backslashes included; one before the closing
# backticks escapes nothing.
check code_keeps_escapes   {{code {a\.b \(x\) \$HOME}}} [pi {`a\.b \(x\) \$HOME`}]
check code_keeps_brackets  {{code {\[x\]}}}      [pi {``\[x\]``}]
check code_keeps_star_bs   {{code {\* \\ x}}}    [pi {`\* \\ x`}]
# Inside a span, a backslash before a backtick run at least the span's
# opening length escapes that many backticks, painted alone, while the span
# can still close later on the same line; the rest of the run is read afresh
# and may close the span.
check code_bs_backtick     {{code {status `ok` done}}} [pi {`status \`ok\` done`}]
check code_bs_then_prose   {{code x`y} {plain { after}}} [pi {`x\`y` after}]
check code_bs_before_close {{code {x `y`}} {plain { w}}} [pi {`x \`y\`` w}]
check code_bs_last_char    {{code {Fn + `}} {plain { key}}} [pi {`Fn + \`` key}]
check code_bs_first_char   {{code `a}}           [pi {`\`a`}]
check code_bs_alone        {{code {a ` b}}}      [pi {`a \` b`}]
check code_bs_dot_literal  {{code {a\.b}}}       [pi {`a\.b`}]
check code_bs_dollar       {{code {\$HOME}}}     [pi {`\$HOME`}]
check code_bs_dbl_span     {{code {x ` y}}}      [pi {`` x ` y ``}]
check code_bs_dbl_escaped  {{code {x `` y}}}     [pi {`` x \`` y ``}]
# Before a run shorter than the opening the backslash is literal: a single
# backtick cannot close a double span. In a single span a double run after
# the backslash is one escaped backtick and a closer.
check code_bs_dbl_single   [list [list code "\\`"]] [pi {`` \` ``}]
check code_bs_dbl_path     [list [list code "`C:\\Drivers\\`"]] [pi {`` `C:\Drivers\` ``}]
check code_bs_single_dbl   {{code {a `}} {plain { b ` c` d}}} [pi {`a \`` b \` c` d}]
# With no closer further on, the backslash is literal and its backtick closes
# the span: Windows paths and a lone backslash.
check code_bs_path_close   [list [list code "C:\\Drivers\\"] {plain { dated}}]  [pi {`C:\Drivers\` dated}]
check code_bs_drive        [list [list code "C:\\"]] [pi {`C:\`}]
check code_bs_lone         [list [list code "\\"]]   [pi {`\`}]
# The rule's cost: a span ending in a backslash, followed by another span on
# the same line, takes the backslash-backtick as escaped and runs on to the
# next span's opener, leaving its closer stray.
check code_bs_next_span    {{code {cd`, }} {plain cd~`}} [pi {`cd\`, `cd~`}]
# An escape needs its closer on the same line, so the same pair on two lines is two
# spans; a span with no escape still closes on a later line.
check code_bs_line_bound   [list {plain {Before: }} [list code "# ... \\"]  [list plain "\nAfter: "] [list code "# ... \\"]]  [pi "Before: `# ... \\`\nAfter: `# ... \\`"]
check code_across_lines    [list [list code "a\nb"] {plain { c}}] [pi "`a\nb` c"]
check bs_backtick_no_span  {{plain {a ` b ` c}}} [pi {a \` b \` c}]
check code_after_escaped_bs [list [list plain "\\"] [list code x]] [pi {\\`x`}]

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

# ---- parse_inline: links, bare URLs and inline images. A link run is
# {link text url}; everything else stays {style chunk}.
check inline_link \
    {{plain {see }} {link docs https://x.org/d} {plain { now}}} \
    [pi {see [docs](https://x.org/d) now}]
check inline_link_title \
    {{link docs https://x.org}} \
    [pi {[docs](https://x.org "Docs")}]
check inline_link_parens \
    {{link Tcl https://en.wikipedia.org/wiki/Tcl_(language)}} \
    [pi {[Tcl](https://en.wikipedia.org/wiki/Tcl_(language))}]
check inline_link_emphasis_raw \
    {{link {**big** news} u.html}} \
    [pi {[**big** news](u.html)}]
check inline_link_in_bold \
    {{bold {see }} {link docs u.html}} \
    [pi {**see [docs](u.html)**}]
check inline_link_in_code \
    {{plain {run }} {code {[a](b) https://x.org}}} \
    [pi {run `[a](b) https://x.org`}]
check inline_not_link \
    {{plain {[a] (b) and [c](d e) and [f]}}} \
    [pi {[a] (b) and [c](d e) and [f]}]
check inline_bare_url \
    {{plain {go to }} {link https://x.org/a https://x.org/a} {plain .}} \
    [pi {go to https://x.org/a.}]
check inline_bare_url_paren \
    [list {plain {(see }} {link http://x.org/a http://x.org/a} {plain {), ok}}] \
    [pi {(see http://x.org/a), ok}]
check inline_bare_url_balanced \
    {{link https://x.org/T_(l) https://x.org/T_(l)} {plain !}} \
    [pi {https://x.org/T_(l)!}]
check inline_bare_url_bold \
    {{bold {link }} {link https://x.org https://x.org}} \
    [pi {**link https://x.org**}]
check inline_autolink \
    {{plain {at }} {link https://x.org https://x.org}} \
    [pi {at <https://x.org>}]
# An angle-bracket autolink takes any scheme; a tag is not one.
check inline_autolink_mailto \
    {{plain {write }} {link mailto:a@b.org mailto:a@b.org}} \
    [pi {write <mailto:a@b.org>}]
check inline_autolink_tel \
    {{link tel:+61-2-5550100 tel:+61-2-5550100}} \
    [pi {<tel:+61-2-5550100>}]
check inline_autolink_https {{link https://example.org/ https://example.org/}} \
    [pi {<https://example.org/>}]
check inline_autolink_mail  {{link mailto:a@b.org mailto:a@b.org}} \
    [pi {<mailto:a@b.org>}]
check inline_autolink_tel2  {{link tel:+61212345678 tel:+61212345678}} \
    [pi {<tel:+61212345678>}]
check inline_autolink_file  {{link file:///etc/hosts file:///etc/hosts}} \
    [pi {<file:///etc/hosts>}]
# A scheme-shaped pair without // or a contact scheme is text, brackets kept.
foreach {name src} {
    xs_element <xs:element>  svg_rect <svg:rect>  w_t <w:t>  t_foo <T:Foo>
    win_path <C:\Users\me\file.txt>
    cpp_template std::vector<std::string>
} {
    check inline_autolink_lit_$name [list [list plain $src]] [pi $src]
}
check inline_autolink_div   {{plain <div>}} [pi {<div>}]
check inline_autolink_a     {{plain {<a href="x">}}} [pi {<a href="x">}]
check inline_url_midword \
    {{plain xhttps://x.org}} \
    [pi {xhttps://x.org}]
check inline_url_not_past_gt \
    {{plain <} {link http://x.org http://x.org} {plain >}} \
    [pi {\<http://x.org>}]
check inline_link_angle_parens \
    {{link a x)y(z} {plain { q}}} \
    [pi {[a](<x)y(z>) q}]
check inline_url_bare_scheme \
    [list {plain https://.}] \
    [pi {https://.}]
check inline_image \
    {{plain {a cat sat}}} \
    [pi {a ![cat](cat.png) sat}]
check inline_image_alt_literal \
    {{plain {see 2*3*4 here}}} \
    [pi {see ![2*3*4](m.png) here}]
check inline_escape_in_link \
    {{link a*b u}} \
    [pi {[a\*b](u)}]

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


# ---- segment_headings: split a body into {heading {level title}} and
# {normal text} segments, ATX and setext, never inside a fence.
check head_atx_levels \
    [list [list heading {1 One}] [list heading {3 Three}] [list heading {6 Six}]] \
    [::tkdown::segment_headings "# One\n### Three\n###### Six"]
check head_atx_closing \
    [list [list heading {2 Title}] [list heading [list 1 C#]] [list heading {2 {}}]] \
    [::tkdown::segment_headings "## Title ##\n# C#\n## ###"]
check head_atx_not \
    [list [list normal "#5 bolt\n####### seven\n#tag"]] \
    [::tkdown::segment_headings "#5 bolt\n####### seven\n#tag"]
check head_atx_inline_kept \
    [list [list heading {2 {The **bold** `x`}}]] \
    [::tkdown::segment_headings "## The **bold** `x`"]
check head_around \
    [list [list normal "intro\n"] [list heading {1 Head}] [list normal "\nbody"]] \
    [::tkdown::segment_headings "intro\n\n# Head\n\nbody"]
check head_setext_h1 \
    [list [list heading {1 Title}] [list normal body]] \
    [::tkdown::segment_headings "Title\n=====\nbody"]
check head_setext_h2 \
    [list [list normal "first line"] [list heading {2 Second}] [list normal body]] \
    [::tkdown::segment_headings "first line\nSecond\n---\nbody"]
check head_setext_after_blank \
    [list [list normal "text\n\n---\nmore"]] \
    [::tkdown::segment_headings "text\n\n---\nmore"]
check head_setext_short \
    [list [list normal "Title\n--"]] \
    [::tkdown::segment_headings "Title\n--"]
check head_table_delim \
    [list [list normal "| a | b |\n|---|---|\n| 1 | 2 |"]] \
    [::tkdown::segment_headings "| a | b |\n|---|---|\n| 1 | 2 |"]
check head_table_unbounded \
    [list [list normal "a | b\n---"]] \
    [::tkdown::segment_headings "a | b\n---"]
check head_setext_not_under_item \
    [list [list normal "- item\n---"]] \
    [::tkdown::segment_headings "- item\n---"]
check head_quote_is_text \
    [list [list normal "> # quoted\n> line\n---"]] \
    [::tkdown::segment_headings "> # quoted\n> line\n---"]
check head_fence_hash \
    [list [list normal "```\n# comment\nfoo\n---\n```"] [list heading {1 After}]] \
    [::tkdown::segment_headings "```\n# comment\nfoo\n---\n```\n# After"]
check head_fence_survives \
    [list [list prose before] [list code "# comment"] [list prose after]] \
    [::tkdown::segment_code_fences [lindex [::tkdown::segment_headings \
        "before\n```tcl\n# comment\n```\nafter"] 0 1]]

# ---- segment_rules: {rule {}} for a thematic break, {normal text} else.
check rule_kinds \
    [list [list rule {}] [list rule {}] [list rule {}] [list rule {}]] \
    [::tkdown::segment_rules "---\n***\n___\n- - -"]
check rule_after_blank \
    [list [list normal "text\n"] [list rule {}] [list normal more]] \
    [::tkdown::segment_rules "text\n\n---\nmore"]
check rule_setext_kept \
    [list [list normal "Heading\n---\nbody"]] \
    [::tkdown::segment_rules "Heading\n---\nbody"]
check rule_after_heading_text \
    [list [list rule {}] [list normal body]] \
    [::tkdown::segment_rules [lindex [::tkdown::segment_headings \
        "# H\n---\nbody"] 1 1]]
check rule_table_delim \
    [list [list normal "| a | b |\n|---|---|"]] \
    [::tkdown::segment_rules "| a | b |\n|---|---|"]
check rule_not \
    [list [list normal "--\n-- -x\n*** bold\n----a"]] \
    [::tkdown::segment_rules "--\n-- -x\n*** bold\n----a"]
check rule_fenced \
    [list [list normal "```\n---\n```"]] \
    [::tkdown::segment_rules "```\n---\n```"]

# ---- segment_images: {image {alt path}} for a line that is only an image.
check image_line \
    [list [list normal intro] [list image {{a cat} img/cat.png}] [list normal outro]] \
    [::tkdown::segment_images "intro\n  !\[a cat\](img/cat.png)  \noutro"]
check image_title \
    [list [list image {logo logo.svg}]] \
    [::tkdown::segment_images {![logo](logo.svg "The logo")}]
check image_inline_left \
    [list [list normal {see ![x](x.png) here}]] \
    [::tkdown::segment_images {see ![x](x.png) here}]
check image_fenced \
    [list [list normal "```\n!\[x\](x.png)\n```"]] \
    [::tkdown::segment_images "```\n!\[x\](x.png)\n```"]

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

# ---- segment_lists: {normal text} / {list items}, each item
# {depth marker text}, marker "•" for a bullet and "N." for an ordered item.
check list_bullet \
    [list [list list {{0 • apples} {0 • pears}}]] \
    [::tkdown::segment_lists "- apples\n- pears"]
check list_star_plus \
    [list [list list {{0 • one} {0 • two}}]] \
    [::tkdown::segment_lists "* one\n+ two"]
check list_numbered \
    [list [list list {{0 1. first} {0 2. second} {0 3. third}}]] \
    [::tkdown::segment_lists "1. first\n2. second\n3. third"]
check list_numbering_kept \
    [list [list list {{0 3. three} {0 7. seven}}]] \
    [::tkdown::segment_lists "3. three\n7. seven"]
check list_mixed_markers \
    [list [list list {{0 • bul} {0 1. ord}}]] \
    [::tkdown::segment_lists "- bul\n1. ord"]
check list_prose_around \
    [list [list normal intro] [list list {{0 • a} {0 • b}}] [list normal "\noutro"]] \
    [::tkdown::segment_lists "intro\n- a\n- b\n\noutro"]
check list_midline_literal \
    [list [list normal "use the - dash key\nrun 3 * 4 now"]] \
    [::tkdown::segment_lists "use the - dash key\nrun 3 * 4 now"]
check list_version_literal \
    [list [list normal "tcl 9.0 and 1.2.3 stay text\n1.2.3 too"]] \
    [::tkdown::segment_lists "tcl 9.0 and 1.2.3 stay text\n1.2.3 too"]
check list_rule_literal \
    [list [list normal "- - -"]] \
    [::tkdown::segment_lists "- - -"]
check list_nested \
    [list [list list {{0 • top} {1 • mid} {2 • deep} {1 • tab} {0 2. back}}]] \
    [::tkdown::segment_lists "- top\n  - mid\n    * deep\n\t- tab\n2. back"]
check list_indented_start \
    [list [list list {{1 • nested}}]] \
    [::tkdown::segment_lists "  - nested"]
check list_lazy \
    [list [list list [list [list 0 • "one\nruns on"] {0 • two}]]] \
    [::tkdown::segment_lists "- one\nruns on\n- two"]
check list_indented_continuation \
    [list [list list [list [list 0 1. "first\nand more"] [list 1 • "sub\ntail"]]]] \
    [::tkdown::segment_lists "1. first\n   and more\n   - sub\n     tail"]
check list_lazy_after_last \
    [list [list list [list {0 • a} [list 0 • "b\noutro"]]]] \
    [::tkdown::segment_lists "- a\n- b\noutro"]
check list_blank_continues \
    [list [list list {{0 • a} {1 • b} {0 • c}}]] \
    [::tkdown::segment_lists "- a\n\n  - b\n\n\n- c"]
check list_blank_ends \
    [list [list list {{0 • a}}] [list normal "\n  indented para"]] \
    [::tkdown::segment_lists "- a\n\n  indented para"]
check list_fence_ends \
    [list [list list {{0 • a}}] [list normal "```\n- not an item\n```"]] \
    [::tkdown::segment_lists "- a\n```\n- not an item\n```"]
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
# 15 lines is the viewer's stated requirement: a 100-character pane shows
# this table no taller than that.
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

# ---- resolve_refs: reference links become inline links ---------------------
proc rr {s} { return [::tkdown::resolve_refs $s] }
check ref_full        "see \[the site\](http://x.org)\n" \
    [rr "see \[the site\]\[x\]\n\n\[x\]: http://x.org"]
check ref_collapsed   "see \[x\](http://x.org)" \
    [rr "see \[x\]\[\]\n\[x\]: http://x.org"]
check ref_shortcut    "see \[x\](http://x.org) now" \
    [rr "see \[x\] now\n\[x\]: http://x.org"]
check ref_def_at_end  "\[up top\](http://x.org)\nbody\n" \
    [rr "\[up top\]\[x\]\nbody\n\[x\]: http://x.org\n"]
check ref_case_ws     "\[a\](http://x.org) \[b\](http://x.org)" \
    [rr "\[a\]\[FOO  Bar\] \[b\]\[foo bar\]\n   \[Foo Bar\]: http://x.org"]
check ref_angle_title "\[a\](<http://x.org/a b>)" \
    [rr "\[a\]\[x\]\n\[x\]: <http://x.org/a b> \"A title\""]
check ref_title_forms "\[a\](u1) \[b\](u2)" \
    [rr "\[a\]\[x\] \[b\]\[y\]\n\[x\]: u1 'one'\n\[y\]: u2 (two)"]
check ref_image       "!\[alt\](http://x.org/i.png)" \
    [rr "!\[alt\]\[img\]\n\[img\]: http://x.org/i.png"]
check ref_footnote    "a\[^1\] here\n\[^1\]: the note" \
    [rr "a\[^1\] here\n\[^1\]: the note"]
check ref_in_fence    "```\n\[a\]\[x\] \[x\]\n```\n\[a\](u)" \
    [rr "```\n\[a\]\[x\] \[x\]\n```\n\[a\]\[x\]\n\[x\]: u"]
check ref_def_in_fence "```\n\[x\]: u\n```\n\[x\]" \
    [rr "```\n\[x\]: u\n```\n\[x\]"]
check ref_in_backticks "`\[a\]\[x\]` and \[a\](u)" \
    [rr "`\[a\]\[x\]` and \[a\]\[x\]\n\[x\]: u"]
check ref_shortcut_undefined "\[x\] and \[y\]" \
    [rr "\[x\] and \[y\]\n\[z\]: u"]
check ref_inline_kept "\[x\](other) and \[x\](u)" \
    [rr "\[x\](other) and \[x\]\n\[x\]: u"]
check ref_full_undefined "\[a\]\[nope\] \[b\](u)" \
    [rr "\[a\]\[nope\] \[b\]\[x\]\n\[x\]: u"]
check ref_not_a_def_indented "    \[x\]: u" [rr "    \[x\]: u"]
check ref_parens_balanced "\[w\](http://x/T_(l))" [rr "\[w\]\n\[w\]: http://x/T_(l)"]
check ref_paren_close "see \[a\](<http://x/a)b>)" [rr "see \[a\]\n\[a\]: http://x/a)b"]
check ref_paren_close_parses {{plain {see }} {link a http://x/a)b}} \
    [pi [rr "see \[a\]\n\[a\]: http://x/a)b"]]
check ref_paren_open "\[a\](<http://x/a(b>)" [rr "\[a\]\n\[a\]: http://x/a(b"]
check ref_crlf "see \[a\](http://x/)\r\n\r\nend\r\n" \
    [rr "see \[a\]\r\n\r\n\[a\]: http://x/\r\nend\r\n"]
check ref_crlf_fence "```\r\n\[a\]\r\n```\r\n\[a\](u)\r\n" \
    [rr "```\r\n\[a\]\r\n```\r\n\[a\]\r\n\[a\]: u\r\n"]

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
