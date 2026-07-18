#!/usr/bin/env tclsh9.0
# The YAML conformance corpus for yamlmuster. yamlmuster is dict-in and
# never parses YAML; what it inherits is whatever the parser feeding it
# produces. This corpus pins that inheritance: each YAML expression class
# runs through tcllib yaml's yaml2dict (default options, as the consumers
# call it) and the result - including every named exclusion and coercion
# the man page declares - is asserted here, so the declared compatibility
# level stays measured, not remembered. Where a class matters to
# validation, the parsed dict also runs through a small ruleset.
package require Tcl 9
set ROOT [file dirname [file dirname [file dirname [file normalize [info script]]]]]
foreach md [glob -directory [file join $ROOT modules] -type d *] { ::tcl::tm::path add $md }
package require yamlmuster

# The corpus needs the parser it measures; a shelf clone without tcllib
# still passes the suite.
if {[catch {package require yaml} yamlver]} {
    puts "SKIPPED (no tcllib yaml)"
    exit 0
}
puts "measuring tcllib yaml $yamlver"

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
proc parse {yamltext} { return [::yaml::yaml2dict $yamltext] }
proc parsefails {name pattern yamltext} {
    set rc [catch {::yaml::yaml2dict $yamltext} msg]
    check $name-raises 1 $rc
    checkmatch $name-msg $pattern $msg
}
proc codes {issues} { lmap i $issues {dict get $i code} }

# -- block scalars: literal and folded, chomping -/+/clip ---------------------

check literal-clip {a {line1
line2
} b end} [parse "a: |\n  line1\n  line2\nb: end"]
check literal-strip {a {line1
line2} b end} [parse "a: |-\n  line1\n  line2\nb: end"]
check literal-keep {a {line1
line2

} b end} [parse "a: |+\n  line1\n  line2\n\nb: end"]
check folded {a {one two
} b end} [parse "a: >\n  one\n  two\nb: end"]

# -- scalar styles ------------------------------------------------------------

check scalar-styles {a plain b single c double} \
    [parse "a: plain\nb: 'single'\nc: \"double\""]

# -- nested block maps and sequences -------------------------------------------

check nested-block {root {sub {k v} seq {p q}}} \
    [parse "root:\n  sub:\n    k: v\n  seq:\n    - p\n    - q"]

# -- flow style, including flow nested in block ---------------------------------

check flow {m {k v j w} s {a b}} [parse "m: {k: v, j: w}\ns: \[a, b\]"]
check flow-in-block {outer {inner {k {1 2}}}} \
    [parse "outer:\n  inner: {k: \[1, 2\]}"]

# -- anchors, aliases (backward), merge key --------------------------------------

check anchor-alias {base hello copy hello} \
    [parse "base: &anch hello\ncopy: *anch"]
check merge-key {defaults {x 1 y 2} item {x 1 y 9}} \
    [parse "defaults: &d\n  x: 1\n  y: 2\nitem:\n  <<: *d\n  y: 9"]

# A merged mapping validates like any other dict.
set v [yamlmuster new]
$v load {
    level root -keys {defaults item}
    level item -keys {x y}
    child root item dict item
    rule require item x -code missing_x
    rule range item y -min 0 -max 5 -integer -code y_range
}
check merge-validates {y_range} \
    [codes [$v validate [parse "defaults: &d\n  x: 1\nitem:\n  <<: *d\n  y: 9"]]]
$v destroy

# -- !!str pins a scalar the parser would otherwise coerce ------------------------

check str-tag-pins {a yes b 1} [parse "a: !!str yes\nb: yes"]

# -- exclusion probes: what this parser refuses or drops --------------------------

# Forward alias references raise; yaml.tcl names the message key
# ANCHOR_NOT_FOUND internally, but what surfaces is this message with an
# empty errorcode.
parsefails forward-alias {*Could not find the anchor-name*} \
    "copy: *notyet\nbase: &notyet hi"

# Tags outside the !! core raise (message key TAG_NOT_FOUND).
parsefails noncore-tag {*handle wasn't declared*} "a: !mytag hello"

# A line beginning with # inside a literal block is dropped as a comment:
# measured content loss, not an error.
check hash-in-literal-drops {a {keep
after
} b end} [parse "a: |\n  keep\n  # dropped\n  after\nb: end"]

# Tabs in plain scalars raise.
parsefails tab-in-plain {*Tabs can be used only in comments*} "a: has\ttab"

# A document whose last line is `key:` with no trailing newline never
# returns: yaml2dict loops. Measured here under an interp time limit so
# the corpus stays honest about it without hanging the suite; feed this
# parser whole files (which end in a newline) or trim-check first.
set ip [interp create]
interp limit $ip time -seconds [expr {[clock seconds] + 5}]
set rc [catch {interp eval $ip {
    package require yaml
    ::yaml::yaml2dict "a: xx\nc:"
}} msg opts]
check trailing-colon-hangs 1 $rc
check trailing-colon-limit {TCL LIMIT TIME} [dict get $opts -errorcode]
catch {interp delete $ip}
check trailing-colon-with-newline-ok {a xx c {}} [parse "a: xx\nc:\n"]

# -- coercion probes: values arrive already transformed ----------------------------

# YAML 1.1 booleans, the Norway problem included: a bare - or + is a
# boolean too.
check coerce-booleans {a 1 b 0 c 1 d 0 e 1 f 0 g 1 h 0} \
    [parse "a: yes\nb: no\nc: y\nd: n\ne: on\nf: off\ng: +\nh: -"]

# By the time rules run, `enabled: yes` is the string 1: a oneof over the
# source-text vocabulary fires. Pin with !!str where the text matters.
set v [yamlmuster new]
$v load {
    level root -keys {enabled}
    rule oneof root enabled {yes no} -code enabled_vocab
}
check coerced-bool-breaks-oneof {enabled_vocab} \
    [codes [$v validate [parse "enabled: yes"]]]
check str-tag-restores-oneof {} \
    [codes [$v validate [parse "enabled: !!str yes"]]]
$v destroy

# null, ~ and empty all arrive as the empty string: require sees the key
# as present, and only -nonblank can tell the difference.
check coerce-null {a {} b {} c {}} [parse "a: null\nb: ~\nc:\n"]
set v [yamlmuster new]
$v load {
    level root -keys {a}
    rule require root a -code a_missing
    rule require root a -nonblank -code a_blank
}
check null-passes-require {a_blank} [codes [$v validate [parse "a: null\n"]]]
$v destroy

# Comma-grouped integers lose their commas (nonstandard), and unquoted
# ISO dates arrive as epoch seconds via clock scan.
check coerce-comma {a 1000} [parse "a: 1,000"]
set d [parse "a: 2026-07-17"]
check coerce-date-integer 1 [string is integer -strict [dict get $d a]]
check coerce-date-epoch [clock scan 2026-07-17] [dict get $d a]

if {$fails} {
    puts "$fails failures"
    exit $fails
} else {
    puts "all tests passed"
    exit 0
}
