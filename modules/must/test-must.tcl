#!/usr/bin/env tclsh9.0
# Tests for the must module: the required literal factor of a regex, and the
# filter command built on it. The property under test is the module's one
# contract: whenever a factor comes back, every string the pattern matches
# contains it (case per the returned flag), so a substring miss soundly
# skips the regex. Constructs the scanner does not model must forfeit the
# factor, never guess one. Pure and Tk-free. Run:
#   tclsh9.0 modules/must/test-must.tcl
package require Tcl 9
set ROOT [file dirname [file dirname [file dirname [file normalize [info script]]]]]
foreach md [glob -directory [file join $ROOT modules] -type d *] { ::tcl::tm::path add $md }
package require must

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
proc factor {args} { return [::must::factor {*}$args] }

# ---- plain extraction -------------------------------------------------------
check plain_literal      {busyduck 0} [factor {busyduck}]
check class_bound        {K9 0}       [factor {[^A-Za-z]K9[^A-Za-z]}]
check anchors_break      {scan 0}     [factor {^scan$}]
check dot_breaks         {ab 0}       [factor {ab.cd.e}]
check escape_breaks      {K9 0}       [factor {K9\.tm}]
check class_shorthand    {foo 0}      [factor {\d+foo}]
check longest_run        {longer 0}   [factor {ab.longer.cd}]

# ---- quantifiers drop the char they govern ----------------------------------
check star_drops         {a 0}  [factor {ab*c}]
check opt_drops          {colo 0} [factor {colou?r}]
check plus_drops         {a 0}  [factor {ab+c}]
check bound_drops        {b 0}  [factor {a{2,3}b}]
check first_longest_tie  {a 0}  [factor {ab*c*}]

# ---- groups: depth-0 runs survive, group content does not -------------------
check group_content_skipped {a 0} [factor {a(b|c)d}]
check group_quantified      {x 0} [factor {x(abc)?}]

# ---- forfeits: constructs the scanner does not model ------------------------
check bail_alternation   {{} 0} [factor {foo|bar}]
check bail_star_director {{} 0} [factor {***=a.c}]
check bail_are_director  {{} 0} [factor {***:foo}]
check bail_embedded_opts {{} 0} [factor {fo(?i)bar}]
check bail_noncapture    {{} 0} [factor {(?:abc)def}]
check bail_expanded      {{} 0} [factor "(?x) M 2"]
check bail_quote_mode    {{} 0} [factor {(?q)a.c}]
check bail_malformed     {{} 0} [factor {a(b}]
check bail_no_literal    {{} 0} [factor {[0-9]{4}}]
check bail_open_brace    {{} 0} [factor "a\{b"]

# ---- bracket expressions ----------------------------------------------------
check bracket_first_pos  {xy 0} [factor {[]a]xy}]
check bracket_negated    {xy 0} [factor {[^]a]xy}]
check bracket_class      {go 0}  [factor {[[:digit:]]go}]
check bracket_collating  {{} 0}  [factor {[[.tab.]xyz]}]
check bracket_escaped_close {{} 0} [factor {[\]x]}]
check bracket_escape_then   {y 0}  [factor {[\]x]y}]

# ---- variable-length escapes forfeit: a fixed 2-char skip would harvest the
# tail of a longer escape (\x41BC is one char then "BC", not "41BC") --------
check bail_hex_escape     {{} 0} [factor {\x41BC}]
check bail_unicode_escape {{} 0} [factor {\u0041zz}]
check bail_bigunicode     {{} 0} [factor {\U00000041zz}]
check bail_control_escape {{} 0} [factor {\cAzz}]
check bail_octal_escape   {{} 0} [factor {\101zz}]
check bail_backref        {{} 0} [factor {(a)\1zz}]
# the filter stays sound where the old 2-char skip dropped a real match.
set keep_hex [::must::filter {\x41BC}]
check filter_hex_match_kept 1 [{*}$keep_hex {the ABC is real}]

# ---- regexp's command flags, mirrored as options -----------------------------
check opt_nocase         {error 1} [factor -nocase {Error}]
check opt_expanded       {{} 0}    [factor -expanded {K9}]
check opt_unknown_errors 1 [catch {::must::factor -bogus {x}}]

# ---- case: a leading (?i) folds the factor ----------------------------------
check director_nocase    {k9 1}  [factor {(?i)K9}]
check director_case_kept {K9 0}  [factor {(?c)K9}]

# ---- any ordinary character joins a run, whatever its alphabet --------------
# The factor is a substring of the match text itself; whether a transformed
# haystack (an escaped or encoded form) preserves these characters is the
# caller's question, not the extractor's.
check nonascii_in_run    {héllo 0}   [factor "héllo"]
check quote_in_run       {say\"hi 0} [factor "say\"hi"]

# ---- soundness property: a factor is a substring of every match -------------
# Each pair is {pattern haystack-that-matches}; the factor must sit inside the
# haystack, lowered on both sides when the flag says nocase.
foreach {pat s} {
    {[^A-Za-z]K9[^A-Za-z]}  { K9.}
    {(?i)K9}                {an k9 here}
    {colou?r}               {color}
    {colou?r}               {colour}
    {a(b|c)d}               {acd}
    {\d+foo}                {42foo}
    {K9\.tm}                {K9.tm}
    {a{2,3}b}               {aab}
    {ab*c}                  {ac}
    {héllo}                 {oh héllo there}
    {[\]x]y}                {]y}
} {
    check "matches:$pat/$s" 1 [regexp -- $pat $s]
    lassign [factor $pat] f fold
    if {$f eq ""} {
        puts "FAIL: factor_empty:$pat (property test expects a factor)"
        incr ::fails
        continue
    }
    set hay [expr {$fold ? [string tolower $s] : $s}]
    check "contains:$pat/$s" 1 [expr {[string first $f $hay] >= 0}]
}

# ---- the filter command: 0 only on a provable miss --------------------------
set keep [::must::filter {[^A-Za-z]K9[^A-Za-z]}]
check filter_hit      1 [{*}$keep {an K9 marker}]
check filter_miss     0 [{*}$keep {nothing here}]
set keep [::must::filter {(?i)K9}]
check filter_fold_hit 1 [{*}$keep {an k9 marker}]
set keep [::must::filter {[0-9]{4}}]
check filter_factorless_passes 1 [{*}$keep {anything at all}]
set keep [::must::filter -nocase {Error}]
check filter_opt_nocase_hit  1 [{*}$keep {AN ERROR AROSE}]
check filter_opt_nocase_miss 0 [{*}$keep {all quiet}]

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
