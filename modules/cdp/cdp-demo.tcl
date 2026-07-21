#!/usr/bin/env tclsh9.0
# A standalone demo of the cdp module against a real browser: launch Chromium
# yourself, point the demo at a page target, and it asks the browser its
# version, evaluates 1+1, and round-trips a multibyte string through the page.
#
#   chromium --headless --remote-debugging-port=9333 about:blank &
#   curl -s http://127.0.0.1:9333/json     # copy webSocketDebuggerUrl
#   CDP_WS_URL=ws://127.0.0.1:9333/devtools/page/XXXX tclsh9.0 cdp-demo.tcl
#
# It loads only the cdp module.

package require Tcl 9
set ROOT [file dirname [file dirname [file dirname [file normalize [info script]]]]]
foreach md [glob -directory [file join $ROOT modules] -type d *] { ::tcl::tm::path add $md }
package require cdp

if {![info exists ::env(CDP_WS_URL)] || $::env(CDP_WS_URL) eq ""} {
    puts stderr "set CDP_WS_URL to a DevTools page target (see the header comment)"
    exit 2
}

set cdp [cdp::connect]

set ver [$cdp cdp Browser.getVersion]
puts "Browser.getVersion product: [dict get $ver result product]"

puts "evaluate {1+1} = [$cdp evaluate {1+1}]"
puts "evaluate multibyte = [$cdp evaluate {"hi \u{1F600} 世界"}]"

$cdp close
