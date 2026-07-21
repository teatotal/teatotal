#!/usr/bin/env tclsh9.0
# Tests for the cdp module, offline: RFC6455 client-frame masking must round-trip
# a multibyte payload (mask with the module's own framing, unmask here mirroring
# a server), across all three payload-length encodings (7-bit, 16-bit, 64-bit);
# connect must fail loudly on a non-ws URL and on an unset CDP_WS_URL. No socket
# and no browser: the wire behaviour against a live DevTools endpoint is the
# demo's job, not the load gate's.
package require Tcl 9
set ROOT [file dirname [file dirname [file dirname [file normalize [info script]]]]]
foreach md [glob -directory [file join $ROOT modules] -type d *] { ::tcl::tm::path add $md }
package require cdp

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

# Unmask a client frame the way an RFC6455 server would.
proc unmask_client_frame {framed} {
    binary scan $framed cucu b0 b1
    set len [expr {$b1 & 0x7f}]
    set off 2
    if {$len == 126} {
        binary scan [string range $framed 2 3] Su len
        set off 4
    } elseif {$len == 127} {
        binary scan [string range $framed 2 9] Wu len
        set off 10
    }
    set mask [string range $framed $off [expr {$off+3}]]
    incr off 4
    set payload [string range $framed $off [expr {$off+$len-1}]]
    binary scan $mask cu4 mb
    binary scan $payload cu* pb
    set out {}
    set i 0
    foreach byte $pb { lappend out [expr {$byte ^ [lindex $mb [expr {$i%4}]]}]; incr i }
    return [encoding convertfrom utf-8 [binary format cu* $out]]
}

# Reach the (unexported) framing method by mixing the class into a bare object
# and exporting the method on that object only.
set probe [oo::object new]
oo::objdefine $probe {
    mixin cdp::Client
    export FrameMasked
}

set small "hello 世界 \U0001F600 mask round-trip"
check "7-bit-length frame round-trips multibyte payload" $small \
    [unmask_client_frame [$probe FrameMasked $small]]

set medium [string repeat "payload-16bit " 40]
check "16-bit-length frame round-trips" $medium \
    [unmask_client_frame [$probe FrameMasked $medium]]

set large [string repeat "payload-64bit-length " 4000]
check "64-bit-length frame round-trips" $large \
    [unmask_client_frame [$probe FrameMasked $large]]

$probe destroy

# connect must refuse a non-ws URL before touching any socket.
check "connect refuses an http:// URL" 1 \
    [catch {cdp::connect http://127.0.0.1:9222/}]

# connect with no argument and no CDP_WS_URL must error, not hang.
set saved ""
if {[info exists ::env(CDP_WS_URL)]} { set saved $::env(CDP_WS_URL); unset ::env(CDP_WS_URL) }
check "connect with nothing to connect to errors" 1 [catch {cdp::connect}]
if {$saved ne ""} { set ::env(CDP_WS_URL) $saved }

if {$fails} { puts "$fails failing"; exit 1 }
puts "all cdp cases passed"
