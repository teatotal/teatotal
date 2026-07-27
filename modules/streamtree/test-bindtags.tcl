#!/usr/bin/env wish9.0
# The list text is an object list, not editable text, so it carries no Text
# class bindtag. What that buys: the class's motion keys end in
# tk::TextSetCursor, which does `see insert`, and a list's insert mark sits at
# the buffer end where the last render left it, so with the class in place one
# arrow key throws the reader to the end of the tree. The class's click
# gestures likewise start a text selection the list has no use for. The wheel
# is the one class binding a list wants, and it is kept on a tag of the
# module's own. The host's toplevel accelerators must survive: they are the
# reason the class is dropped by bindtag rather than by a widget-level break,
# which would abort the whole chain.

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file dirname [file normalize [info script]]]]]
foreach md [glob -directory [file join $ROOT modules] -type d *] { ::tcl::tm::path add $md }
package require streamtree
set ::env(STREAMTREE_AUDIT) 1

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name\n  expected: $expected\n  actual:   $actual"
        incr ::fails
    } else { puts "ok:   $name" }
}

pack [ttk::frame .f] -fill both -expand 1
set d [::streamtree::StreamTree new]
$d setup .f
set T .f.body.t
# Enough rows that the view can scroll, so a key that moves it shows up.
set root [$d insert "" folder all [dict create label All]]
$d node_set $root expanded 1
for {set i 0} {$i < 200} {incr i} {
    $d insert $root item row$i [dict create label "row $i"]
}
update

check "the Text class bindtag is off the list" 0 \
    [expr {[lsearch -exact [bindtags $T] Text] >= 0}]
check "the widget, the toplevel and all stay on it" 1 \
    [expr {[bindtags $T] eq [list $T StreamtreeWheel [winfo toplevel $T] all]}]
check "the class's wheel scripts are kept" 1 \
    [expr {[bind StreamtreeWheel <MouseWheel>] eq [bind Text <MouseWheel>]}]

# The insert mark is where a render leaves it, which is what made the class's
# motion keys dangerous. Assert the premise, then that no key acts on it.
check "the insert mark sits at the buffer end" 1 \
    [expr {[$T compare insert >= "end - 2 chars"]}]
focus -force $T
update
foreach k {<Key-Down> <Key-End> <Key-Next> <Control-Key-b> <Control-Key-e>} {
    # Re-park the mark each round: a key that moved it would otherwise leave
    # the next key with nothing far away to scroll to, and pass for that.
    $T mark set insert "end - 1 chars"
    $T yview moveto 0
    update
    event generate $T $k
    update
    check "$k leaves the view where the reader put it" 0.0 [lindex [$T yview] 0]
}

# A press-drag-release paints no text selection.
$T yview moveto 0
update
event generate $T <ButtonPress-1> -x 20 -y 10
event generate $T <B1-Motion> -x 20 -y 90
event generate $T <ButtonRelease-1> -x 20 -y 90
update
check "a drag starts no text selection" {} [$T tag ranges sel]

# A host accelerator on the toplevel still fires while the list holds focus.
set ::hit 0
bind [winfo toplevel $T] <Control-b> {incr ::hit}
event generate $T <Control-Key-b>
update
check "the toplevel's accelerator still reaches its binding" 1 $::hit

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
