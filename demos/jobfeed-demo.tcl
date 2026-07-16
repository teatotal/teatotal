#!/usr/bin/env tclsh9.0
# A standalone demo of jobfeed: the intake layer in front of a job pool. A
# fake work source is polled and its rows are deduplicated into a jobloop; a
# gate defers one class of work while a budget is spent; one item is delivered
# by hand ahead of the poll and gets its own sequenced run; and every reaped
# outcome lands in the feed's history. It loads only jobfeed and jobloop, no
# Tk, no threads, on the event loop the script already has.
#
# Run it:   tclsh9.0 demos/jobfeed-demo.tcl

package require Tcl 9
set HERE [file dirname [file normalize [info script]]]
::tcl::tm::path add [file dirname $HERE]
package require jobfeed
package require jobloop

# The dispatch: "run" one item and return a JSON result line. AI work
# succeeds; the one BI item fails, to show an error reaching history.
proc runItem {poolkind group id} {
    if {$group eq "BI"} {
        return "{\"status\":\"error\",\"detail\":\"no session for $group:$id\"}"
    }
    return "{\"status\":\"done\",\"detail\":\"$group:$id handled\"}"
}

# The source: a command prefix the feed polls. It hands back the current board.
set ::board {}
proc pollSource {callback} { {*}$callback $::board }

# A feed with a policy in one override. The gate admits AI work up to a
# two-launch budget, defers BI work until it is allowed, and waves any
# hand-delivered run straight through. Everything else is the module default.
oo::class create DemoFeed {
    superclass jobfeed
    variable Items Budget Ran AllowBI
    constructor {source dispatch pool} {
        set Budget 2; set Ran 0; set AllowBI 0
        next $source $dispatch $pool -poll 0
    }
    method allowBI {} { set AllowBI 1; my drain }
    method gate {job kind} {
        set item [dict get $Items $job]
        if {[dict get $item delivered]} { return "" }
        if {[dict get $item group] eq "BI"} {
            return [expr {$AllowBI ? "" : "defer"}]
        }
        if {$Ran >= $Budget} { return defer }   ;# the budget bounds AI work
        incr Ran
        return ""
    }
}

set pool [jobloop new 4]
set feed [DemoFeed new [list pollSource] runItem $pool]
$pool register a [list $feed jobWorker]
$pool register b [list $feed jobWorker]

$feed subscribe {apply {{event detail} {
    puts [format "  %-11s %s" $event $detail]
}}}

puts "A source is polled into a two-kind pool. The gate runs AI work up to a"
puts "two-launch budget, defers BI work until it is allowed, and waves a"
puts "hand-delivered run straight through. Watch the budget spend on AI:1 and"
puts "AI:2 then hold the rest, an injected AI:7 run ahead of the spent budget,"
puts "the still-queued BI:9 dedup when poll 2 repeats the board, and BI:9 reach"
puts "history only once it is allowed.\n"

set ::board [list \
    [dict create group AI id 1 poolkind a] \
    [dict create group AI id 2 poolkind a] \
    [dict create group BI id 9 poolkind b]]
puts "-- poll 1 --"
$feed pullNow

after 250 { puts "-- inject AI:7 by hand --"; $feed inject AI 7 a "" console }
after 500 { puts "-- poll 2 (AI:1 repeats) --"; $feed pullNow }
after 800 { puts "-- allow BI --"; $feed allowBI }

after 1400 { set ::done 1 }
vwait ::done

puts "\nHistory (every reaped outcome, kept for a status view):"
foreach {key row} [$feed history] {
    puts [format "   %-8s %-6s %s" $key [dict get $row status] [dict get $row detail]]
}
$feed destroy
$pool destroy
puts "\nDone. The budget ran AI:1 and AI:2 then deferred the AI rows a second"
puts "poll re-queued; the injected AI:7 ran ahead of the budget; BI:9 stayed"
puts "queued (deduped on the second poll) until allowed, then errored."
