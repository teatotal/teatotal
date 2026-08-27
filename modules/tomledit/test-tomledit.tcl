#!/usr/bin/env tclsh9.0
# Tests for the tomledit module. The property under test is the module's one
# contract: an edit to one path changes only that key's bytes. The `surgery`
# helper peels the common prefix and suffix off a before/after pair, so a
# result of {{old} {new}} is proof that every other byte of the document is
# identical. Pure and Tk-free. Run:
#   tclsh9.0 modules/tomledit/test-tomledit.tcl
package require Tcl 9
set ROOT [file dirname [file dirname [file dirname [file normalize [info script]]]]]
foreach md [glob -directory [file join $ROOT modules] -type d *] { ::tcl::tm::path add $md }
package require tomledit

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

# Which lines an edit replaced: common prefix and suffix peeled off, so
# {{old} {new}} proves every other byte identical. {} on either side is a
# pure deletion or insertion.
proc surgery {before after} {
    set a [split $before "\n"]
    set b [split $after "\n"]
    set p 0
    while {$p < [llength $a] && $p < [llength $b]
           && [lindex $a $p] eq [lindex $b $p]} {
        incr p
    }
    set i [expr {[llength $a] - 1}]
    set j [expr {[llength $b] - 1}]
    while {$i >= $p && $j >= $p && [lindex $a $i] eq [lindex $b $j]} {
        incr i -1
        incr j -1
    }
    return [list [lrange $a $p $i] [lrange $b $p $j]]
}

# A config file with everything a writer must not disturb: a header
# comment block, blank lines, odd spacing, a trailing same-line comment,
# a key and a table the editing tool knows nothing about.
set fixture {# The workshop machine.
# Do not let the bloom get away from you again.

[general]
font_scaling   =   1.2	# bigger type, fewer rows
effects_frame_skip = 2


# the look
[screen]
name = "Deep Blue"
bloom = 0.9
mystery_key = "kept"

[dotfiles_tool]
generated_at = "2026-08-01"
}

# A file whose `[[ssh.host]]` rows carry everything a row writer must not
# disturb: a comment block introducing a row, odd spacing, a trailing
# same-line comment, an unknown key inside a row, an unknown key in the
# `[ssh]` table itself, and a table after the last row.
set sshfixture {# Servers.

[ssh]
default = "backup"
odd_key = "kept"

# the backup box, offsite
[[ssh.host]]
host = "backup"
user   =   "admin"	# the account, not the person
note = "unknown to this tool"

[[ssh.host]]
host = "relay"
port = 2222

[[ssh.host]]
host = "spare"

[dotfiles_tool]
generated_at = "2026-08-01"
}

set tmpdir [file tempdir]

# ---- parse ------------------------------------------------------------------
set p [tomledit::parse $fixture]
check parse_tables_keys_raw \
    {2 {"Deep Blue"} 0.9 {"2026-08-01"}} \
    [list [dict get $p tables general effects_frame_skip] \
        [dict get $p tables screen name] \
        [dict get $p tables screen bloom] \
        [dict get $p tables dotfiles_tool generated_at]]
check parse_trailing_comment_not_value 1.2 \
    [dict get $p tables general font_scaling]
set arraydoc "\[values\]\nsize = \[\n    \"s\",\n    \"m\",\n\]\n\n\[\[row\]\]\nname = \"a\"\n\n\[\[row\]\]\nname = \"b\"\n"
set pa [tomledit::parse $arraydoc]
check parse_rows_in_order {{"a"} {"b"}} \
    [lmap entry [dict get $pa arrays row] { dict get $entry name }]
check parse_multiline_array_is_one_value {[ "s", "m", ]} \
    [dict get $pa tables values size]
check parse_hash_in_string_not_comment {"#ff8100"} \
    [dict get [tomledit::parse "\[screen\]\nfont_color = \"#ff8100\" # amber\n"] \
        tables screen font_color]

# ---- paths ------------------------------------------------------------------
check path_get_raw {"Deep Blue"} [tomledit::get $fixture screen.name]
check path_get_fallback 0.3 [tomledit::get $fixture screen.margin 0.3]
check path_get_row_key 2222 [tomledit::get $sshfixture {ssh.host[1].port}]
check path_get_row_key_fallback 22 \
    [tomledit::get $sshfixture {ssh.host[2].port} 22]
check path_get_absent_row_fallback none \
    [tomledit::get $fixture {ssh.host[0].host} none]
check path_dotted_table_splits_at_last_dot {"vault"} \
    [tomledit::get "\[ssh\]\ndefault = \"vault\"\n" ssh.default]
check path_malformed_is_error {1 1 1} \
    [list [catch {tomledit::get $fixture screen}] \
        [catch {tomledit::put $fixture {ssh.host[1]} x}] \
        [catch {tomledit::del $fixture .bloom}]]
check path_count {3 0 0} \
    [list [tomledit::count $sshfixture ssh.host] \
        [tomledit::count $fixture ssh.host] \
        [tomledit::count $sshfixture ssh.other]]

# ---- put --------------------------------------------------------------------
check put_touches_one_line {{{bloom = 0.9}} {{bloom = 0.4}}} \
    [surgery $fixture [tomledit::put $fixture screen.bloom 0.4]]
check put_keeps_spacing_and_comment \
    "{{font_scaling   =   1.2\t# bigger type, fewer rows}} {{font_scaling   =   1.5\t# bigger type, fewer rows}}" \
    [surgery $fixture [tomledit::put $fixture general.font_scaling 1.5]]
check put_new_key_moves_nothing_else {{} {{jitter = 0.0}}} \
    [surgery $fixture [tomledit::put $fixture screen.jitter 0.0]]
set out [tomledit::put $fixture general.window_scaling 1.25]
check put_new_key_lands_in_table 1.25 [tomledit::get $out general.window_scaling]
set lines [split $out "\n"]
check put_new_key_above_next_tables_comment \
    {{} {} {# the look} {[screen]} {name = "Deep Blue"} {bloom = 0.9} {mystery_key = "kept"} {} {[dotfiles_tool]} {generated_at = "2026-08-01"}} \
    [lrange $lines [expr {[lsearch -exact $lines {window_scaling = 1.25}] + 1}] end-1]
set out [tomledit::put $fixture chassis.shell {"switchboard"}]
check put_absent_table_appended \
    "1 {\n\[chassis\]\nshell = \"switchboard\"\n}" \
    [list [string equal $fixture [string range $out 0 [expr {[string length $fixture] - 1}]]] \
        [string range $out [string length $fixture] end]]
check put_missing_file_is_empty_document \
    "\[screen\]\nname = \"E-Ink\"\n" \
    [tomledit::put [tomledit::read_file \
        [file join $tmpdir no-such-dir config.toml]] screen.name {"E-Ink"}]

# ---- del: keys --------------------------------------------------------------
check del_removes_one_line {{{bloom = 0.9}} {}} \
    [surgery $fixture [tomledit::del $fixture screen.bloom]]
set out [tomledit::del $fixture dotfiles_tool.generated_at]
check del_last_key_keeps_header \
    {{{{generated_at = "2026-08-01"}} {}} 1} \
    [list [surgery $fixture $out] \
        [dict exists [tomledit::parse $out] tables dotfiles_tool]]
check del_absent_is_byte_noop {1 1} \
    [list [string equal $fixture [tomledit::del $fixture screen.margin]] \
        [string equal $fixture [tomledit::del $fixture nosuch.key]]]
check del_same_name_other_table_untouched \
    "\[a\]\nk = 1\n\n\[b\]\n" \
    [tomledit::del "\[a\]\nk = 1\n\n\[b\]\nk = 2\n" b.k]

# ---- rows: put and del inside them ------------------------------------------
check row_put_touches_one_line {{{port = 2222}} {{port = 2200}}} \
    [surgery $sshfixture [tomledit::put $sshfixture {ssh.host[1].port} 2200]]
check row_put_keeps_spacing_and_comment \
    "{{user   =   \"admin\"\t# the account, not the person}} {{user   =   \"root\"\t# the account, not the person}}" \
    [surgery $sshfixture [tomledit::put $sshfixture {ssh.host[0].user} {"root"}]]
set out [tomledit::put $sshfixture {ssh.host[2].key} {"~/.ssh/spare"}]
check row_put_absent_key_added_inside \
    {{{} {{key = "~/.ssh/spare"}}} {"~/.ssh/spare"}} \
    [list [surgery $sshfixture $out] [tomledit::get $out {ssh.host[2].key}]]
set out [tomledit::put $sshfixture {ssh.host[2].host} {"relay"}]
check row_put_same_key_other_row_untouched \
    {{"backup"} {"relay"} {"relay"}} \
    [lmap entry [dict get [tomledit::parse $out] arrays ssh.host] { dict get $entry host }]
check row_del_removes_one_line {{{port = 2222}} {}} \
    [surgery $sshfixture [tomledit::del $sshfixture {ssh.host[1].port}]]
check row_del_absent_is_byte_noop 1 \
    [string equal $sshfixture [tomledit::del $sshfixture {ssh.host[0].key}]]
check row_bad_index_is_error {1 1 1} \
    [list [catch {tomledit::put $sshfixture {ssh.host[3].host} {"x"}}] \
        [catch {tomledit::del $sshfixture {ssh.host[9]}}] \
        [catch {tomledit::del $fixture {ssh.host[0].host}}]]

# ---- rows: add and remove ---------------------------------------------------
check add_after_last \
    {{} {{[[ssh.host]]} {host = "cache"} {port = 2200} {}}} \
    [surgery $sshfixture [tomledit::add \
        $sshfixture ssh.host {host {"cache"} port 2200}]]
check add_first_lands_after_parent_table \
    "\[general\]\nk = 1\n\n\[ssh\]\ndefault = \"a\"\n\n\[\[ssh.host\]\]\nhost = \"a\"\n" \
    [tomledit::add "\[general\]\nk = 1\n\n\[ssh\]\ndefault = \"a\"\n" \
        ssh.host {host {"a"}}]
check add_into_empty_document \
    "\[\[ssh.host\]\]\nhost = \"a\"\n" \
    [tomledit::add "" ssh.host {host {"a"}}]
set text "\[ssh\]\ndefault = \"a\"\n\n# the dotfiles tool wrote this\n\[dotfiles_tool\]\ngenerated_at = \"2026-08-01\"\n"
check add_above_next_tables_comment \
    {{} {{[[ssh.host]]} {host = "a"} {}}} \
    [surgery $text [tomledit::add $text ssh.host {host {"a"}}]]
check row_remove_middle_leaves_neighbours \
    {{{host = "relay"} {port = 2222} {} {[[ssh.host]]}} {}} \
    [surgery $sshfixture [tomledit::del $sshfixture {ssh.host[1]}]]
check row_remove_leaves_next_rows_comment \
    "# the backup box\n\[\[ssh.host\]\]\nhost = \"b\"\n" \
    [tomledit::del \
        "\[\[ssh.host\]\]\nhost = \"a\"\n\n# the backup box\n\[\[ssh.host\]\]\nhost = \"b\"\n" \
        {ssh.host[0]}]
set out [tomledit::del $sshfixture {ssh.host[2]}]
check row_remove_last_no_doubled_blank \
    {{{{[[ssh.host]]} {host = "spare"} {}} {}} -1} \
    [list [surgery $sshfixture $out] [string first "\n\n\n" $out]]
check row_remove_at_eof_takes_blank_line \
    "\[ssh\]\ndefault = \"a\"\n" \
    [tomledit::del "\[ssh\]\ndefault = \"a\"\n\n\[\[ssh.host\]\]\nhost = \"a\"\n" \
        {ssh.host[0]}]

# ---- ensure_table -----------------------------------------------------------
set text "\[\[ssh.host\]\]\nhost = \"a\"\n"
set out [tomledit::ensure_table $text ssh ssh.host]
check ensure_creates_above_rows \
    [list "\[ssh\]\n\n\[\[ssh.host\]\]\nhost = \"a\"\n" \
        "\[ssh\]\ndefault = \"a\"\n\n\[\[ssh.host\]\]\nhost = \"a\"\n"] \
    [list $out [tomledit::put $out ssh.default {"a"}]]
set text "\[general\]\nk = 1\n\n# the backup box\n\[\[ssh.host\]\]\nhost = \"a\"\n"
check ensure_goes_above_first_rows_comment \
    {{} {{[ssh]} {}}} \
    [surgery $text [tomledit::ensure_table $text ssh ssh.host]]
check ensure_present_is_byte_noop 1 \
    [string equal $sshfixture [tomledit::ensure_table $sshfixture ssh ssh.host]]
check ensure_no_rows_appends \
    "\[general\]\nk = 1\n\n\[ssh\]\n" \
    [tomledit::ensure_table "\[general\]\nk = 1\n" ssh ssh.host]

# ---- scalar types and formatting --------------------------------------------
check type_from_raw_spelling \
    {string bool bool int int float float float string} \
    [lmap raw {{"x"} true false 12 -3 1.0 0.45 1.0e3 bare_word} { tomledit::type_of $raw }]
check float_always_carries_point {1.0 0.45 0.0} \
    [lmap v {1 0.45 0.0} {tomledit::format_value float $v}]
check string_escapes_out {"a \"b\" c\\d"} \
    [tomledit::format_value string {a "b" c\d}]
check string_roundtrips {a "b" c\d} \
    [tomledit::plain [tomledit::format_value string {a "b" c\d}]]
check escaped_string_in_file_reads_plain {a "b" c} \
    [tomledit::plain [tomledit::get \
        "\[screen\]\nfont_name = \"a \\\"b\\\" c\"\n" screen.font_name]]
set raw [tomledit::get "\[fonts\]\nname = '\"Atari800\"'\n" fonts.name]
check literal_string_parses_types_unquotes {1 string 1} \
    [list [string equal $raw {'"Atari800"'}] [tomledit::type_of $raw] \
        [string equal [tomledit::plain $raw] {"Atari800"}]]

# ---- the unsafe guard -------------------------------------------------------
check guard_fixtures_inside_subset {{} {} {}} \
    [list [tomledit::unsafe $fixture] [tomledit::unsafe $sshfixture] [tomledit::unsafe ""]]
# The construct that motivates the guard: the string's body holds a line
# shaped like a header, and an unguarded put would edit inside the string
# instead of the real table.
check guard_multiline_string_named \
    {line 2 holds a multiline string delimiter} \
    [tomledit::unsafe "\[general\]\nbanner = \"\"\"\nwelcome\n\[screen\]\n\"\"\"\n"]
check guard_multiline_literal_refused \
    {line 2 holds a multiline string delimiter} \
    [tomledit::unsafe "\[general\]\nb = '''\nx\n'''\n"]
check guard_dotted_key_refused \
    {line 2 holds the dotted key physical.shape} \
    [tomledit::unsafe "\[screen\]\nphysical.shape = \"round\"\n"]
check guard_inline_table_refused \
    {line 2 holds an inline table} \
    [tomledit::unsafe "\[extra\]\npoint = { x = 1, y = 2 }\n"]
check guard_multiline_array_refused \
    {line 2 opens a multiline array} \
    [tomledit::unsafe "\[extra\]\nxs = \[\n1,\n2,\n\]\n"]

# ---- files ------------------------------------------------------------------
check read_missing_is_empty {} \
    [tomledit::read_file [file join $tmpdir absent config.toml]]
set path [file join $tmpdir rt config.toml]
set text "$fixture# a lone comment, no trailing newline\n# and a é in it"
tomledit::atomic_write $path $text
check write_read_roundtrips_bytes 1 \
    [string equal $text [tomledit::read_file $path]]
set path [file join $tmpdir rt2 config.toml]
tomledit::atomic_write $path "\[screen\]\n"
check write_lands_by_rename_no_temp_left {config.toml} \
    [glob -nocomplain -tails -types f -directory [file dirname $path] * .*]

file delete -force $tmpdir
if {$fails == 0} { puts PASS } else { puts "FAILED: $fails" }
exit $fails
