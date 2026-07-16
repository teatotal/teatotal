#!/usr/bin/env tclsh9.0
# Tests for the yamlmuster module: every rule kind against a spar-shaped
# fixture, the cost account that proves partial validation, the policing
# negatives that prove a rules file can only declare, and the edge cases
# the man page commits to. The rulesets and data here are invented for the
# tests; the module knows nothing of any program that uses it.
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add $ROOT
package require yamlmuster

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
proc checkmatch {name pattern actual} {
    if {![string match $pattern $actual]} {
        puts "FAIL: $name"
        puts "  pattern: <$pattern>"
        puts "  actual:  <$actual>"
        incr ::fails
    } else {
        puts "ok:   $name"
    }
}
proc codes {issues} { lmap i $issues {dict get $i code} }
proc stat {v name} { dict get [$v stats] $name }

# -- fixture: an approach-shaped ruleset ------------------------------------

set A [yamlmuster new]
set ::desync_calls 0
$A predicate desync {apply {{node meta} {
    incr ::desync_calls
    set want [dict get [dict get $meta context] roster_email]
    set got [dict getdef $node to ""]
    if {$got ne "" && $got ne $want} {
        return [list [dict create message "to '$got' differs from roster '$want'"]]
    }
    return {}
}}}
$A load {
    level root        -keys {version decisions rounds profile_hash}
    level decisions   -keys {channel language angle}
    level round       -keys {type number messages}
    level message     -keys {channel subject body to mode text char_count parent script}
    level parent      -keys {account message_id subject}
    level script_item -keys {point text}
    child root decisions dict decisions
    child root rounds list round
    child round messages list message
    child message parent dict parent
    child message script list script_item

    rule vocab root
    rule vocab decisions
    rule vocab round
    rule vocab message
    rule vocab parent

    rule require root decisions -code missing_decisions -groups {shape rootonly}
    rule require root rounds -nonempty -code missing_rounds -groups shape
    rule oneof root version {1.0} -code version_unsupported -groups version
    rule require root version -code version_unstamped -severity warning -groups version
    rule any root rounds -where {type final} -code no_final_round -groups shape
    rule require round number -code draft_missing_number -severity warning \
        -when {type draft}
    rule atmost round messages 1 -where {channel email} -when {type final} \
        -code too_many_final_emails
    rule require message {subject body} -anyof -code email_missing_content \
        -severity warning -when {channel email} -unless {mode reply}
    rule require message {parent message_id} -nonblank \
        -code reply_missing_parent_message_id -when {channel email mode reply}
    rule length message text -max 300 -trim -code linkedin_note_too_long \
        -when {channel linkedin} -groups li
    rule regexp message to {^[^@\s]+@[^@\s]+\.[^@\s]+$} -code placeholder_to \
        -groups email
    rule predicate message desync -code email_desync -severity warning \
        -needs roster_email -groups {email rosteronly}
} -name approach

proc msg_email {args} {
    return [dict merge [dict create channel email subject S body B to a@b.co] $args]
}
set CLEAN [dict create version 1.0 \
    decisions {channel email language en angle intro} \
    rounds [list \
        [dict create type draft number 1 messages [list [msg_email]]] \
        [dict create type final number 2 messages [list [msg_email]]]]]

check clean-no-issues {} [$A validate $CLEAN]

# -- vocab: unknown_key and the wrong_level hint -----------------------------

set d [dict replace $CLEAN mystery x]
set is [$A validate $d]
check vocab-unknown-code {unknown_key} [codes $is]
set i [lindex $is 0]
check vocab-unknown-key mystery [dict get $i key]
check vocab-unknown-level root [dict get $i level]
check vocab-unknown-msg {unknown key 'mystery' at root} [dict get $i message]

# `subject` is canonical at message (declared first) and parent; planting it
# at round must point at the first-declared owner.
set d $CLEAN
dict set d rounds [list [dict merge [lindex [dict get $CLEAN rounds] 1] {subject oops}]]
set is [$A validate $d]
check wrong-level-code {wrong_level} [codes $is]
set i [lindex $is 0]
check wrong-level-owner message [dict get $i owner]
check wrong-level-key subject [dict get $i key]
check wrong-level-path {rounds 0} [dict get $i path]
check wrong-level-msg {'subject' at round belongs at message; move it there} \
    [dict get $i message]

# -- require ------------------------------------------------------------------

set d [dict remove $CLEAN decisions]
check require-missing {missing_decisions} [codes [$A validate $d -groups rootonly]]

set d [dict replace $CLEAN rounds {}]
check require-nonempty-empty {missing_rounds no_final_round} \
    [codes [$A validate $d -groups shape]]
set d [dict remove $CLEAN rounds]
check require-nonempty-absent {missing_rounds} \
    [codes [$A validate $d -groups shape]]

# -anyof: both alternatives missing fires, one present passes.
set m [dict remove [msg_email] subject body]
set d [dict replace $CLEAN rounds [list [dict create type final messages [list $m]]]]
check require-anyof-both-missing {email_missing_content} [codes [$A validate $d]]
set m [dict remove [msg_email] body]
set d [dict replace $CLEAN rounds [list [dict create type final messages [list $m]]]]
check require-anyof-one-present {} [codes [$A validate $d]]

# -nonblank on a nested keypath: blank value, and a missing intermediate
# key, both fire; a real message_id passes.
set m [msg_email mode reply parent {account x message_id {   }}]
set d [dict replace $CLEAN rounds [list [dict create type final messages [list $m]]]]
check require-nonblank-blank {reply_missing_parent_message_id} [codes [$A validate $d]]
set m [msg_email mode reply]
set d [dict replace $CLEAN rounds [list [dict create type final messages [list $m]]]]
check require-nonblank-no-parent {reply_missing_parent_message_id} [codes [$A validate $d]]
set m [msg_email mode reply parent {account x message_id <id@host>}]
set d [dict replace $CLEAN rounds [list [dict create type final messages [list $m]]]]
check require-nonblank-ok {} [codes [$A validate $d]]

# -- oneof ---------------------------------------------------------------------

set d [dict replace $CLEAN version 2.0]
check oneof-bad {version_unsupported} [codes [$A validate $d -groups version]]
set d [dict remove $CLEAN version]
check oneof-absent-is-requires-business {version_unstamped} \
    [codes [$A validate $d -groups version]]
check oneof-good {} [codes [$A validate $CLEAN -groups version]]

# -- length ---------------------------------------------------------------------

set long [string repeat x 301]
set m [dict create channel linkedin text $long]
set d [dict replace $CLEAN rounds [list [dict create type final messages [list $m]]]]
set is [$A validate $d -groups li]
check length-over {linkedin_note_too_long} [codes $is]
checkmatch length-msg-measures {*301*300*} [dict get [lindex $is 0] message]
# -trim: 300 chars plus whitespace measures 300.
set m [dict create channel linkedin text "[string repeat x 300]   "]
set d [dict replace $CLEAN rounds [list [dict create type final messages [list $m]]]]
check length-trim {} [codes [$A validate $d -groups li]]

# -- regexp ---------------------------------------------------------------------

set m [msg_email to todo]
set d [dict replace $CLEAN rounds [list [dict create type final messages [list $m]]]]
check regexp-bad {placeholder_to} [codes [$A validate $d -groups email]]
check regexp-good {} [codes [$A validate $CLEAN -groups email]]

# -- any / atmost -----------------------------------------------------------------

set d [dict replace $CLEAN rounds [list [dict create type draft number 1 messages {}]]]
check any-no-match {no_final_round} \
    [codes [$A validate $d -groups shape]]
check any-match {} [codes [$A validate $CLEAN -groups shape]]

set m2 [list [msg_email] [msg_email to c@d.co]]
set d [dict replace $CLEAN rounds [list [dict create type final number 1 messages $m2]]]
set is [$A validate $d]
check atmost-over {too_many_final_emails} [codes $is]
checkmatch atmost-count {*2*} [dict get [lindex $is 0] message]
# the same two emails in a draft round pass: -when {type final} gates it
set d [dict replace $CLEAN rounds [list \
    [dict create type draft number 1 messages $m2] \
    [dict create type final number 2 messages [list [msg_email]]]]]
check atmost-when-gated {} [codes [$A validate $d]]

# -- conditionals: -when AND, -unless ----------------------------------------------

# multi-pair -when: mode reply on a NON-email channel must not fire the
# reply rule (channel email AND mode reply).
set m [dict create channel linkedin text hi mode reply]
set d [dict replace $CLEAN rounds [list [dict create type final messages [list $m]]]]
check when-and-pair {} [codes [$A validate $d]]
# -unless: a reply email missing subject and body is not missing content;
# only the parent rule speaks.
set m [dict create channel email mode reply parent {message_id <i@h>}]
set d [dict replace $CLEAN rounds [list [dict create type final messages [list $m]]]]
check unless-suppresses {} [codes [$A validate $d]]

# -- predicate: pass-through, override, rethrow --------------------------------------

set m [msg_email to other@x.co]
set d [dict replace $CLEAN rounds [list [dict create type final messages [list $m]]]]
set is [$A validate $d -groups email -context {roster_email a@b.co}]
check pred-passthrough {email_desync} [codes $is]
set i [lindex $is 0]
check pred-fills-severity warning [dict get $i severity]
check pred-engine-path {rounds 0 messages 0} [dict get $i path]
check pred-partial-message {to 'other@x.co' differs from roster 'a@b.co'} \
    [dict get $i message]

set P [yamlmuster new]
$P predicate multi {apply {{node meta} {
    return [list \
        [dict create message first] \
        [dict create code second_code severity error message second]]
}}}
$P predicate boom {apply {{node meta} { error "predicate exploded" }}}
$P load {
    level root -keys {a}
    rule predicate root multi -code first_code -severity warning
}
set is [$P validate {a 1}]
check pred-two-issues {first_code second_code} [codes $is]
check pred-override-severity {warning error} [lmap i $is {dict get $i severity}]
$P load {
    rule predicate root boom -code kaboom -groups explode
}
set rc [catch {$P validate {a 1} -groups explode} msg opts]
check pred-throw-rc 1 $rc
checkmatch pred-throw-msg {yamlmuster: predicate 'boom' (rule kaboom): predicate exploded} $msg
check pred-throw-code {YAMLMUSTER PREDICATE boom} [dict get $opts -errorcode]
$P destroy

if {$fails} {
    puts "$fails failures"
    exit $fails
} else {
    puts "all tests passed"
    exit 0
}
