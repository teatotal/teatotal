#!/usr/bin/env tclsh9.0
# A standalone demo of tomledit: path-addressed edits landing in a
# hand-written config file whose every other byte survives. It loads only
# the tomledit module - no Tk.
#
# Run it:   tclsh9.0 modules/tomledit/tomledit-demo.tcl

package require Tcl 9
set HERE [file dirname [file normalize [info script]]]
foreach md [glob -directory [file dirname $HERE] -type d *] { ::tcl::tm::path add $md }
package require tomledit

set doc {# The workshop machine. Hands off the comments.

[screen]
name = "Deep Blue"
bloom   =   0.9	# cranked on purpose
mystery_key = "some other tool's"

[ssh]
default = "backup"

# the backup box, offsite
[[ssh.host]]
host = "backup"
user = "admin"
}

proc show {title text} {
    puts "$title"
    puts "  | [join [split $text \n] "\n  | "]"
}

show "1. A config file the user wrote - comments, odd spacing, a key ours\n   knows nothing about:" $doc

puts "\n2. The guard first: is this document inside the subset line surgery\n   can edit without guessing?"
puts "   unsafe -> \"[tomledit::unsafe $doc]\"  (empty means safe to edit)\n"

set edited [tomledit::put $doc screen.bloom [tomledit::format_value float 0.4]]
show "3. put screen.bloom 0.4 - one line changed, its spacing and\n   trailing comment kept:" $edited

set edited [tomledit::add $edited ssh.host \
    [list host [tomledit::format_value string relay] port [tomledit::format_value int 2222]]]
show "\n4. add ssh.host - a new row after the last one:" $edited

set edited [tomledit::del $edited {ssh.host[0]}]
show "\n5. del ssh.host\[0\] - the first row and its own comment go, the\n   rest keeps its bytes:" $edited

puts "\n6. Reading back: get gives raw values, plain unquotes them."
set raw [tomledit::get $edited screen.name]
puts "   get screen.name -> $raw   plain -> [tomledit::plain $raw]"
puts "   get ssh.host\[0\].port -> [tomledit::get $edited {ssh.host[0].port}]"
puts "   count ssh.host -> [tomledit::count $edited ssh.host]"
