#!/usr/bin/env tclsh9.0
# A standalone demo of yamlmuster: a small campaign-file ruleset, a clean
# and a broken dict validated whole, two partial passes with the stats
# that show what each one paid, and a hostile rules string refused at
# load. It loads only the yamlmuster module - no Tk, and no YAML parser:
# the validator is dict-in, so the "files" here are dicts already parsed.
#
# Run it:   tclsh9.0 demos/yamlmuster-demo.tcl

package require Tcl 9
set HERE [file dirname [file normalize [info script]]]
foreach md [glob -directory [file dirname $HERE] -type d *] { ::tcl::tm::path add $md }
package require yamlmuster

proc say {text} { puts "\n== $text" }
proc show {issues} {
    if {![llength $issues]} { puts "   (clean)"; return }
    foreach i $issues {
        puts "   [dict get $i severity] [dict get $i code] @ [expr {
            [llength [dict get $i path]] ? [join [dict get $i path] /] : "root"
        }]: [dict get $i message]"
    }
}
proc paid {v} {
    set s [$v stats]
    puts "   paid: [dict get $s rules_selected] rules selected,\
[dict get $s rules_evaluated] evaluated,\
[dict get $s nodes_visited] nodes visited"
}

set v [yamlmuster new]

# A host predicate: the escape hatch for a check the flat kinds cannot
# say. This one wants an external fact (today's date) and is dropped,
# and counted, whenever the caller does not supply it.
$v predicate not_expired {apply {{node meta} {
    set today [dict get [dict get $meta context] today]
    set until [dict getdef $node valid_until ""]
    if {$until ne "" && $until < $today} {
        return [list [dict create message "campaign expired $until"]]
    }
    return {}
}}}

$v load {
    level root    -keys {version title valid_until sender segments}
    level sender  -keys {smtp_host smtp_user smtp_port}
    level segment -keys {name quota}
    child root sender dict sender
    child root segments list segment

    rule require root title -nonblank -code title_missing
    rule oneof root version {1.0} -code version_unsupported
    rule vocab root
    rule require root sender -code sender_missing -groups send
    rule require sender smtp_host -nonblank -code smtp_host_missing -groups send
    rule range sender smtp_port -integer -severity warning \
        -code smtp_port_non_numeric -groups send
    rule require segment name -nonblank -code segment_unnamed -groups segments
    rule range segment quota -min 1 -integer -code segment_quota -groups segments
    rule predicate root not_expired -code campaign_expired -needs today
} -name campaign

set clean {
    version 1.0
    title {Winter growers}
    valid_until 2026-09-01
    sender {smtp_host mail.example.net smtp_user grower smtp_port 587}
    segments {{name north quota 20} {name south quota 15}}
}
set broken {
    version 2.0
    titel {Winter growers}
    sender {smtp_host {} smtp_port later}
    segments {{name {} quota 0} {name south quota 15}}
}

say "the clean dict, every rule (context supplies 'today')"
show [$v validate $clean -context {today 2026-07-17}]
paid $v

say "the broken dict, every rule"
show [$v validate $broken -context {today 2026-07-17}]
paid $v

say "partial: -groups segments pays only for the segment walk"
show [$v validate $broken -groups segments]
paid $v

say "partial: -groups send -limit 1 is a transition gate"
show [$v validate $broken -groups send -limit 1]
paid $v

say "no 'today' in context: the predicate is dropped and the account says so"
$v validate $clean
puts "   rules_skipped_needs = [dict get [$v stats] rules_skipped_needs]"

say "a hostile rules file can only declare"
set hostile {level extra -keys {x}
exec ls /}
if {[catch {$v load $hostile -name hostile} msg]} {
    puts "   refused: $msg"
}
puts "   ruleset intact: [dict get [$v info rules] count] rules,\
groups {[$v info groups]}"

$v destroy
