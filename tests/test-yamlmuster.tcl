#!/usr/bin/env tclsh9.0
# Tests for the yamlmuster module: every rule kind against an approach-shaped
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

# -- the cost account: partial validation as a tested feature -----------------

# Deep data: 30 rounds x 5 messages, each message carrying a parent and a
# script subtree the selected groups never pay for.
set deepmsgs {}
for {set j 0} {$j < 5} {incr j} {
    lappend deepmsgs [dict create channel linkedin text "note $j" \
        parent {account a message_id <i@h>} script {{point p text t}}]
}
set deeprounds {}
for {set i 0} {$i < 29} {incr i} {
    lappend deeprounds [dict create type draft number $i messages $deepmsgs]
}
lappend deeprounds [dict create type final number 30 messages $deepmsgs]
set DEEP [dict create version 1.0 \
    decisions {channel email language en angle intro} rounds $deeprounds]

# A root-only group pays for one node.
check cost-rootonly-clean {} [$A validate $DEEP -groups rootonly]
check cost-rootonly-visits 1 [stat $A nodes_visited]
check cost-rootonly-evaluated 1 [stat $A rules_evaluated]

# A message-level group pays for root, the rounds, and the messages -
# 1 + 30 + 150 - and never descends into parent or script.
check cost-li-clean {} [$A validate $DEEP -groups li]
check cost-li-visits 181 [stat $A nodes_visited]
check cost-li-evaluated 150 [stat $A rules_evaluated]

# -severities {error} prunes warning rules before traversal: the fixture
# holds 17 rules; unfiltered selection drops only the needs-gated one
# (16 selected, 1 skipped), the error band drops the 4 warning rules and
# never reaches the needs check on the warning predicate.
$A validate $DEEP
check cost-sev-default-selected 16 [stat $A rules_selected]
check cost-sev-default-skipped 1 [stat $A rules_skipped_needs]
$A validate $DEEP -severities error
check cost-sev-error-selected 13 [stat $A rules_selected]
check cost-sev-error-skipped 0 [stat $A rules_skipped_needs]

# -limit 1: an early planted error stops the walk; the run pays less than
# an unlimited one, returns exactly one error, and returns the same one
# every time.
set d $DEEP
set r0 [lindex $deeprounds 0]
dict set r0 alien 1
set r25 [lindex $deeprounds 25]
dict set r25 alien2 1
set d [dict replace $DEEP rounds [lreplace $deeprounds 0 0 $r0]]
set d [dict replace $d rounds [lreplace [dict get $d rounds] 25 25 $r25]]
set unlimited [$A validate $d]
set full_cost [stat $A rules_evaluated]
check limit-unlimited-errors 2 [llength $unlimited]
set one [$A validate $d -limit 1]
check limit-one-error {unknown_key} [codes $one]
check limit-cheaper 1 [expr {[stat $A rules_evaluated] < $full_cost}]
check limit-deterministic $one [$A validate $d -limit 1]

# -needs unmet: the account counts the drop AND the predicate command was
# never invoked; met, it runs.
set before $::desync_calls
$A validate $DEEP -groups rosteronly
check needs-unmet-skipped 1 [stat $A rules_skipped_needs]
check needs-unmet-selected 0 [stat $A rules_selected]
check needs-unmet-never-called $before $::desync_calls
$A validate $DEEP -groups rosteronly -context {roster_email a@b.co}
check needs-met-called 1 [expr {$::desync_calls > $before}]

# -- policing: a rules script can only declare ---------------------------------

# Reference verdict to prove atomicity against.
set refdata [dict replace $CLEAN version 9.9]
set refissues [$A validate $refdata]
check policing-ref-sane {version_unsupported} [codes $refissues]

foreach {what script} {
    set             {set x 5}
    exec            {exec ls}
    open            {open /etc/passwd r}
    source          {source /etc/passwd}
    package         {package require json}
    eval            {eval {level q -keys {a}}}
    interp          {interp create}
    while           {while 1 {}}
} {
    set rc [catch {$A load "level q$what -keys {a}\n$script"} msg opts]
    check policing-$what-throws 1 $rc
    checkmatch policing-$what-msg "yamlmuster: rules 'rules' line 2: invalid command name*" $msg
    check policing-$what-code {YAMLMUSTER LOAD rules 2} [dict get $opts -errorcode]
    check policing-$what-atomic $refissues [$A validate $refdata]
}

# A failed load's declarations never commit: the level it staged can be
# declared again by the next, clean load.
set rc [catch {$A load "level ghost -keys {a}\nrule bogus ghost"} msg]
check staging-discarded-rc 1 $rc
checkmatch staging-discarded-msg {*unknown rule kind 'bogus'*} $msg
set rc [catch {$A load "level ghost -keys {a}\nchild root profile_hash dict ghost"} msg]
check staging-reusable 0 $rc

# -- load-time fail-loud ---------------------------------------------------------

set F [yamlmuster new]
foreach {what script pattern} {
    unknown-kind    {level root -keys {a}
rule bogus root}                        {*unknown rule kind 'bogus'*}
    missing-code    {level root -keys {a}
rule require root a}                    {*-code is required*}
    bad-option      {level root -keys {a}
rule require root a -code c -frob 1}    {*unknown option '-frob'*}
    bad-severity    {level root -keys {a}
rule require root a -code c -severity fatal} {*-severity must be error or warning*}
    undeclared-rule-level {level root -keys {a}
rule require ghost a -code c}           {*level 'ghost' not declared*}
    undeclared-child-level {level root -keys {a}
child root a dict ghost}                {*level 'ghost' not declared*}
    no-root         {level top -keys {a}
rule require top a -code c}             {*no 'root' level*}
    unreachable-level {level root -keys {a}
level island -keys {b}
rule require island b -code c}          {*not reachable from root*}
    duplicate-level {level root -keys {a}
level root -keys {b}}                   {*level 'root' already declared*}
    unregistered-predicate {level root -keys {a}
rule predicate root nobody -code c}     {*predicate 'nobody' not registered*}
    vocab-with-code {level root -keys {a}
rule vocab root -code c}                {*-code is not accepted*}
    empty-oneof     {level root -keys {a}
rule oneof root a {} -code c}           {*empty value set*}
    length-no-max   {level root -keys {a}
rule length root a -code c}             {*-max is required*}
    range-no-bound  {level root -keys {a}
rule range root a -code c}              {*at least one of -min, -max, -integer*}
    bad-regexp      {level root -keys {a}
rule regexp root a {[} -code c}         {*bad pattern*}
    any-no-where    {level root -keys {a}
rule any root a -code c}                {*-where {field value ...} is required*}
    atmost-bad-cap  {level root -keys {a}
rule atmost root a lots -code c}        {*cap must be a non-negative integer*}
} {
    set rc [catch {$F load $script} msg opts]
    check load-$what-throws 1 $rc
    checkmatch load-$what-msg $pattern $msg
    checkmatch load-$what-code {YAMLMUSTER LOAD rules *} [dict get $opts -errorcode]
}
check load-failures-left-nothing {count 0 codes {}} [$F info rules]
$F destroy

set rc [catch {$A predicate desync whatever} msg opts]
check predicate-duplicate-rc 1 $rc
check predicate-duplicate-code {YAMLMUSTER PREDICATE desync} [dict get $opts -errorcode]

# A cross-load duplicate level errors too: the union compiles, so a second
# load cannot quietly redeclare the first one's vocabulary.
set rc [catch {$A load {level root -keys {other}}} msg]
check duplicate-level-across-loads 1 $rc
checkmatch duplicate-level-across-loads-msg {*already declared*} $msg

# -- edge cases -------------------------------------------------------------------

# Odd-length node: one bad_node error, path included, descent pruned;
# -badnode ignore skips it silently.
set d [dict replace $CLEAN rounds [list [lindex [dict get $CLEAN rounds] 1] {three item list}]]
set is [$A validate $d]
check badnode-code {bad_node} [codes $is]
check badnode-path {rounds 1} [dict get [lindex $is 0] path]
check badnode-severity error [dict get [lindex $is 0] severity]
check badnode-ignore {} [$A validate $d -badnode ignore]

# Root not a dict: a single bad_node and nothing else; silent under ignore.
set is [$A validate scalar]
check badroot {bad_node} [codes $is]
check badroot-path {} [dict get [lindex $is 0] path]
check badroot-ignore {} [$A validate scalar -badnode ignore]

# A missing child key skips descent silently; absence is require's business.
set m [dict create channel linkedin text hi]
set d [dict replace $CLEAN rounds [list [dict create type final messages [list $m]]]]
check missing-subtree-silent {} [codes [$A validate $d -groups li]]

# Empty and comment-only loads compile to zero rules; validate pays nothing.
set E [yamlmuster new]
$E load {}
$E load "# only a comment\n# and another"
check empty-load-rules {count 0 codes {}} [$E info rules]
check empty-load-validate {} [$E validate {a 1}]
check empty-load-stats [dict create rules_selected 0 rules_evaluated 0 \
    rules_skipped_needs 0 nodes_visited 0 issues_emitted 0 errors_emitted 0] \
    [$E stats]
$E destroy

# Unknown group: an error, never a silent empty pass.
set rc [catch {$A validate $CLEAN -groups typo} msg opts]
check unknown-group-rc 1 $rc
check unknown-group-msg {yamlmuster: unknown group 'typo'} $msg
check unknown-group-code {YAMLMUSTER GROUP typo} [dict get $opts -errorcode]

# Bad option values fail loudly.
foreach {what call code} {
    bad-limit    {-limit some}       {YAMLMUSTER OPTION -limit}
    bad-badnode  {-badnode maybe}    {YAMLMUSTER OPTION -badnode}
    bad-severity {-severities fatal} {YAMLMUSTER SEVERITY fatal}
    bad-option   {-frobnicate 1}     {YAMLMUSTER OPTION -frobnicate}
} {
    set rc [catch {$A validate $CLEAN {*}$call} msg opts]
    check validate-$what-rc 1 $rc
    check validate-$what-code $code [dict get $opts -errorcode]
}

# -limit counts errors only: a warning arrives first and does not stop the
# walk; the first error does.
set d [dict replace $CLEAN rounds [list \
    [dict create type draft messages {}] \
    [dict create type final messages $m2]]]
set is [$A validate $d -limit 1]
check limit-skips-warnings {draft_missing_number too_many_final_emails} [codes $is]

# -extra stamps every issue; engine keys win the collision.
set d [dict replace $CLEAN version 9.9]
set is [$A validate $d -extra {contact_name Ada code SPOOF}]
set i [lindex $is 0]
check extra-stamped Ada [dict get $i contact_name]
check extra-engine-wins version_unsupported [dict get $i code]

# A predicate registered after a load serves the next load; the compiled
# rules are untouched.
set L [yamlmuster new]
set rc [catch {$L load {level root -keys {a}
rule predicate root late -code c}} msg]
check late-predicate-refused 1 $rc
$L predicate late {apply {{node meta} { return {} }}}
set rc [catch {$L load {level root -keys {a}
rule predicate root late -code c}} msg]
check late-predicate-accepted 0 $rc
$L destroy

# -- two instances coexist ------------------------------------------------------

set B [yamlmuster new]
$B load {
    level root   -keys {version sender star_rating yield}
    level sender -keys {smtp_host smtp_user smtp_port}
    child root sender dict sender
    rule require root sender -code sender_missing
    rule require sender smtp_host -nonblank -code smtp_host_missing
    rule range sender smtp_port -integer -severity warning -code smtp_port_non_numeric
    rule range root star_rating -min 1 -max 5 -integer -code invalid_star_rating
    rule range root yield -min 0 -integer -code invalid_yield
} -name campaign

set CAMP {version 1.0 sender {smtp_host mail.x.co smtp_user u smtp_port 587} star_rating 3 yield 2}
check b-clean {} [$B validate $CAMP]

# range: absent skips (presence is require's business), a present
# non-numeric value is the issue, bounds and -integer each speak.
check range-absent-skips {} [$B validate {version 1.0 sender {smtp_host h smtp_user u}}]
check range-non-numeric {smtp_port_non_numeric} \
    [codes [$B validate [dict replace $CAMP sender {smtp_host h smtp_port abc}]]]
check range-under {invalid_star_rating} [codes [$B validate [dict replace $CAMP star_rating 0]]]
check range-over {invalid_star_rating} [codes [$B validate [dict replace $CAMP star_rating 6]]]
check range-not-integer {invalid_yield} [codes [$B validate [dict replace $CAMP yield 1.5]]]
check range-min-zero-ok {} [$B validate [dict replace $CAMP yield 0]]

# The instances share nothing: A's ruleset is what it was, B's groups are
# empty while A's are not, and A still validates its own canon.
check a-unchanged 17 [dict get [$A info rules] count]
check b-groups {} [$B info groups]
check a-still-valid {} [$A validate $CLEAN]
$B destroy
$A destroy

if {$fails} {
    puts "$fails failures"
    exit $fails
} else {
    puts "all tests passed"
    exit 0
}
