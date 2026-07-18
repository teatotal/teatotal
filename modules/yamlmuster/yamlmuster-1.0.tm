package require Tcl 9
package require TclOO
package provide yamlmuster 1.0

# yamlmuster - a rule-indexed validator for parsed YAML: partial validation
# that bills only the checks you select, and policed rule loading from a
# rules file that can only declare.
#
# yamlmuster is dict-in: it never parses YAML. A parser - tcllib's yaml,
# for the programs this grew in - turns the file into a Tcl dict, and
# yamlmuster validates the dict. The verified compatibility level, YAML 1.1
# as tcllib yaml 0.4.2 parses it with its exclusions measured class by
# class, is declared in the man page; the name promises no more than the
# parser feeding it delivers.
#
# A hand-grown validator is one proc per file shape: every check hard-wired
# into a single walking order, every caller paying for the whole walk when
# it wanted one answer, and the vocabulary of levels and keys restated in
# each branch that reads it. Add a check and the proc grows another arm;
# ask a cheaper question - "any errors? stop at the first" - and there is
# no way to ask, because the cost lives in the code shape rather than in
# the call.
#
# yamlmuster indexes the checks instead. Rules declare the level they fire
# at, group tags, and a static severity; a validate call selects rules
# first - by group, by severity, by which context facts the caller
# supplied - then walks only the subtrees holding selected rules and stops
# at the caller's error limit. A deselected rule costs one lookup; an
# unpaid subtree is never entered; and `stats` accounts for every node
# visit and rule evaluation, so partial validation is a number a test
# asserts, not a hope.
#
# The rules arrive as a script evaluated in a policed interpreter. Not
# merely safe: after construction the child's entire command table is
# `level`, `child`, and `rule` - no set, no proc, no expr, no if, and no
# ::tcl:: or ::oo:: name reachable qualified. A rules file can declare and
# do nothing else; `exec ls` in one dies at load with its line number, and
# a failed load leaves the previous ruleset untouched.
#
#   set v [yamlmuster new]
#   $v predicate fresh ::myapp::check_fresh       ;# host escape hatch
#   $v load {
#       level root  -keys {version rounds}
#       level round -keys {type number}
#       child root rounds list round
#       rule oneof root version {1.0} -code version_unsupported
#       rule require root rounds -nonempty -code missing_rounds -groups shape
#       rule any root rounds -where {type final} -code no_final_round \
#           -groups shape
#       rule predicate round fresh -code stale_round -needs today
#   }
#   set issues [$v validate $data -groups shape -limit 1]
#   $v stats    ;# what that pass paid: rules selected/evaluated/skipped,
#               ;# nodes visited, issues and errors emitted
#
# THE RULES FILE - three verbs, flat, no script bodies:
#   level <name> -keys {k ...}          a level and its closed vocabulary;
#                                       `root` is the traversal entry
#   child <parent> <key> dict|list <lv> nesting: at <parent>, <key> holds
#                                       one <lv> dict or a list of them
#   rule <kind> <level> <args> ?opts?   a check attached to a level
#
# Rule kinds: vocab (closed vocabulary; emits unknown_key and wrong_level),
# require (presence, -anyof/-nonblank/-nonempty), oneof (value in a set),
# length (-max/-min/-trim), regexp, range (-min/-max/-integer), any (a list
# holds a matching element), atmost (a matching-element cap), predicate (a
# host command by registered name). Common options: -code (required except
# vocab), -severity error|warning, -groups, -when/-unless (equality gates
# on sibling fields), -needs (context names), -message (%k %v %p %n).
#
# VALIDATION - $v validate $data ?-groups g? ?-severities s? ?-context d?
# ?-extra d? ?-limit n? ?-badnode issue|ignore? returns issue dicts
# {severity code message path level ?key?} plus every -extra pair; engine
# keys win a collision. An unknown group is an error, never a silent empty
# pass. Evaluation order is deterministic: rules in declaration order at
# each node, child edges in declaration order, list elements in data
# order, so -limit 1 returns the same first error every run.
#
# Load errors are loud and atomic: unknown kinds, missing -code, duplicate
# levels, undeclared or unreachable levels, unregistered predicates all
# abort the load whole, as {YAMLMUSTER LOAD <label> <line>}. The engine
# does no I/O anywhere: the host reads the rules file and the data file,
# yamlmuster sees only strings and dicts.
#
# Written against Tcl 9. MIT license, copyright (c) 2025 Weiwu Zhang.

oo::class create yamlmuster {
    # Committed ruleset: raw declarations (reloaded into staging at each
    # load, so loads are additive) and the compiled index built from them.
    variable Preds          ;# dict: predicate name -> cmdprefix
    variable DeclLevels     ;# dict: level -> keys, declaration order
    variable DeclChildren   ;# list of edges {parent key mode child}
    variable Rules          ;# list of rule dicts, declaration order
    variable Levels         ;# dict: level -> {keys {} children {key {mode level}}}
    variable KeyOwners      ;# dict: key -> levels declaring it (wrong_level hints)
    variable ByLevel        ;# dict: level -> rule ids, declaration order
    variable Parents        ;# dict: level -> parent levels (reverse edges)
    variable Groups         ;# dict: group tag -> 1 (registry -groups checks against)
    variable Stats          ;# last validate's cost account
    # Staging, live only inside one load call.
    variable StageLevels StageChildren StageRules
    # Walk state, live only inside one validate call.
    variable WSelected WNeeded WIssues WContext WExtra WLimit WBadnode
    variable WEvaluated WVisited WErrors

    constructor {} {
        set Preds [dict create]
        set DeclLevels [dict create]
        set DeclChildren {}
        set Rules {}
        set Levels [dict create]
        set KeyOwners [dict create]
        set ByLevel [dict create]
        set Parents [dict create]
        set Groups [dict create]
        set Stats [my ZeroStats]
    }

    # Register a host predicate. Must precede any load whose rules name it:
    # the load-time existence check is what turns a typo into a line-numbered
    # load error instead of a validate-time surprise. Re-registering errors -
    # silent shadowing would let one ruleset change what another one meant.
    method predicate {name cmdprefix} {
        if {[dict exists $Preds $name]} {
            throw [list YAMLMUSTER PREDICATE $name] \
                "yamlmuster: predicate '$name' already registered"
        }
        dict set Preds $name $cmdprefix
        return
    }

    # Evaluate a rules script in a fresh policed interp. Additive across
    # calls, and atomic per call: declarations stage into a copy of the
    # committed ruleset, the compile runs over the union, and only a fully
    # compiled index swaps in. Any error - in the script or the compile -
    # leaves the previous ruleset untouched. The host reads files and
    # passes text; load takes no paths.
    method load {script args} {
        if {[llength $args] % 2} {
            throw {YAMLMUSTER OPTION load} \
                "yamlmuster: load options must be option-value pairs"
        }
        set label rules
        foreach {o v} $args {
            switch -- $o {
                -name   { set label $v }
                default {
                    throw [list YAMLMUSTER OPTION $o] \
                        "yamlmuster: unknown option '$o' to load"
                }
            }
        }
        set StageLevels $DeclLevels
        set StageChildren $DeclChildren
        set StageRules $Rules

        # The policed interp, built fresh per load and deleted after - no
        # state carries between loads. -safe removes the dangerous half;
        # the rest is policing, measured in the tests:
        #   1. delete ::oo while `namespace` is still alive - a safe interp
        #      ships TclOO, and ::oo::class stays reachable by qualified
        #      name after global hiding;
        #   2. hide every exposed global command;
        #   3. delete ::tcl through the now-hidden `namespace` - this
        #      removes ::tcl::mathfunc/::tcl::mathop and guts the hidden
        #      ensembles, which nothing will invoke again.
        # After that the child resolves exactly three names: the aliases.
        set ip [interp create -safe]
        catch {interp eval $ip {namespace delete ::oo}}
        foreach c [interp eval $ip {info commands}] { interp hide $ip $c }
        catch {interp invokehidden $ip namespace delete ::tcl}
        foreach verb {level child rule} {
            # Registration-only instance methods, reached through the
            # instance namespace's `my` (they are unexported by their
            # capitalised names). Nothing they do evaluates caller code.
            interp alias $ip $verb {} \
                [info object namespace [self]]::my Dsl_$verb
        }
        set rc [catch {interp eval $ip $script} msg opts]
        interp delete $ip
        if {$rc} {
            # The eval trace carries the failing command's start line as
            # `("interp eval" body line N)`; the marker is absent when
            # that command starts on line 1.
            set line 1
            regexp {\("interp eval" body line (\d+)\)} \
                [dict get $opts -errorinfo] -> line
            throw [list YAMLMUSTER LOAD $label $line] \
                "yamlmuster: rules '$label' line $line: $msg"
        }
        my Compile $label
        return
    }

    # -- the DSL verbs (alias targets; errors here surface with the rules
    # script's line number) ---------------------------------------------

    method Dsl_level {name args} {
        if {[llength $args] != 2 || [lindex $args 0] ne "-keys"} {
            error "level '$name': expected `level $name -keys {k ...}`"
        }
        if {[dict exists $StageLevels $name]} {
            error "level '$name' already declared"
        }
        dict set StageLevels $name [lindex $args 1]
        return
    }

    method Dsl_child {parent key mode child} {
        if {$mode ni {dict list}} {
            error "child '$parent $key': mode must be dict or list, got '$mode'"
        }
        foreach e $StageChildren {
            if {[lindex $e 0] eq $parent && [lindex $e 1] eq $key} {
                error "child '$parent $key' already declared"
            }
        }
        lappend StageChildren [list $parent $key $mode $child]
        return
    }

    method Dsl_rule {kind level args} {
        # Positional arity and per-kind flags/value-options.
        switch -- $kind {
            vocab     { set npos 0; set flags {}; set kopts {} }
            require   { set npos 1
                        set flags {-anyof anyof -nonblank nonblank -nonempty nonempty}
                        set kopts {} }
            oneof     { set npos 2; set flags {}; set kopts {} }
            length    { set npos 1; set flags {-trim trim}
                        set kopts {-max max -min min} }
            regexp    { set npos 2; set flags {}; set kopts {} }
            range     { set npos 1; set flags {-integer integer}
                        set kopts {-min min -max max} }
            any       { set npos 1; set flags {}; set kopts {-where where} }
            atmost    { set npos 2; set flags {}; set kopts {-where where} }
            predicate { set npos 1; set flags {}; set kopts {} }
            default   { error "unknown rule kind '$kind'" }
        }
        if {[llength $args] < $npos} {
            error "rule $kind $level: expected $npos positional argument(s)"
        }
        set pos [lrange $args 0 $npos-1]
        set opts [lrange $args $npos end]

        # Kind parameters, defaulted then filled from flags/options.
        set params [dict create]
        switch -- $kind {
            require { dict set params keypath [lindex $pos 0]
                      dict set params anyof 0
                      dict set params nonblank 0
                      dict set params nonempty 0 }
            oneof   { dict set params keypath [lindex $pos 0]
                      dict set params values [lindex $pos 1] }
            length  { dict set params keypath [lindex $pos 0]
                      dict set params max ""
                      dict set params min ""
                      dict set params trim 0 }
            regexp  { dict set params keypath [lindex $pos 0]
                      dict set params re [lindex $pos 1] }
            range   { dict set params keypath [lindex $pos 0]
                      dict set params min ""
                      dict set params max ""
                      dict set params integer 0 }
            any     { dict set params listkey [lindex $pos 0]
                      dict set params where "" }
            atmost  { dict set params listkey [lindex $pos 0]
                      dict set params n [lindex $pos 1]
                      dict set params where "" }
            predicate { dict set params name [lindex $pos 0] }
        }

        set code ""; set severity error; set groups {}
        set when {}; set unless {}; set needs {}; set message ""
        set common {-code -severity -groups -when -unless -needs -message}
        for {set i 0} {$i < [llength $opts]} {incr i} {
            set o [lindex $opts $i]
            if {[dict exists $flags $o]} {
                dict set params [dict get $flags $o] 1
                continue
            }
            if {![dict exists $kopts $o] && $o ni $common} {
                error "rule $kind $level: unknown option '$o'"
            }
            if {$i + 1 >= [llength $opts]} {
                error "rule $kind $level: option '$o' needs a value"
            }
            set v [lindex $opts [incr i]]
            if {[dict exists $kopts $o]} {
                dict set params [dict get $kopts $o] $v
                continue
            }
            switch -- $o {
                -code     { set code $v }
                -severity {
                    if {$v ni {error warning}} {
                        error "rule $kind $level: -severity must be error or warning, got '$v'"
                    }
                    set severity $v
                }
                -groups   { set groups $v }
                -when     {
                    if {[llength $v] % 2} {
                        error "rule $kind $level: -when needs field-value pairs"
                    }
                    set when $v
                }
                -unless   {
                    if {[llength $v] % 2} {
                        error "rule $kind $level: -unless needs field-value pairs"
                    }
                    set unless $v
                }
                -needs    { set needs $v }
                -message  { set message $v }
            }
        }

        # Per-kind validation, at declaration so the error carries a line.
        switch -- $kind {
            vocab {
                if {$code ne ""} {
                    error "rule vocab $level: vocab emits the built-in codes unknown_key and wrong_level; -code is not accepted"
                }
                if {$message ne ""} {
                    error "rule vocab $level: vocab composes its own messages; -message is not accepted"
                }
                set code vocab   ;# introspection placeholder, never emitted
            }
            oneof {
                if {![llength [dict get $params values]]} {
                    error "rule oneof $level: empty value set can never pass"
                }
            }
            length {
                if {[dict get $params max] eq ""} {
                    error "rule length $level: -max is required"
                }
                foreach b {max min} {
                    set bv [dict get $params $b]
                    if {$bv ne "" && ![string is integer -strict $bv]} {
                        error "rule length $level: -$b must be an integer, got '$bv'"
                    }
                }
            }
            regexp {
                if {[catch {regexp -- [dict get $params re] ""}]} {
                    error "rule regexp $level: bad pattern '[dict get $params re]'"
                }
            }
            range {
                if {[dict get $params min] eq "" && [dict get $params max] eq "" \
                        && ![dict get $params integer]} {
                    error "rule range $level: at least one of -min, -max, -integer required"
                }
                foreach b {min max} {
                    set bv [dict get $params $b]
                    if {$bv ne "" && ![string is double -strict $bv]} {
                        error "rule range $level: -$b must be numeric, got '$bv'"
                    }
                }
            }
            any {
                set w [dict get $params where]
                if {$w eq "" || [llength $w] % 2} {
                    error "rule any $level: -where {field value ...} is required"
                }
            }
            atmost {
                set n [dict get $params n]
                if {![string is integer -strict $n] || $n < 0} {
                    error "rule atmost $level: cap must be a non-negative integer, got '$n'"
                }
                if {[llength [dict get $params where]] % 2} {
                    error "rule atmost $level: -where needs field-value pairs"
                }
            }
            require {
                if {![llength [dict get $params keypath]]} {
                    error "rule require $level: empty keypath"
                }
            }
            predicate {
                set pname [dict get $params name]
                if {![dict exists $Preds $pname]} {
                    error "rule predicate $level: predicate '$pname' not registered"
                }
            }
        }
        if {$kind ne "vocab" && $code eq ""} {
            error "rule $kind $level: -code is required"
        }

        lappend StageRules [dict create id -1 kind $kind level $level \
            code $code severity $severity groups $groups when $when \
            unless $unless needs $needs message $message params $params]
        return
    }

    # End-of-load compile over the staged union: resolve forward
    # references, reject undeclared and unreachable levels, build the
    # index, and swap it in whole.
    method Compile {label} {
        foreach edge $StageChildren {
            lassign $edge parent key mode child
            foreach l [list $parent $child] {
                if {![dict exists $StageLevels $l]} {
                    throw [list YAMLMUSTER LOAD $label 0] \
                        "yamlmuster: rules '$label': child '$parent $key': level '$l' not declared"
                }
            }
        }
        foreach r $StageRules {
            if {![dict exists $StageLevels [dict get $r level]]} {
                throw [list YAMLMUSTER LOAD $label 0] \
                    "yamlmuster: rules '$label': rule '[dict get $r code]': level '[dict get $r level]' not declared"
            }
        }
        if {[llength $StageRules] && ![dict exists $StageLevels root]} {
            throw [list YAMLMUSTER LOAD $label 0] \
                "yamlmuster: rules '$label': rules declared but no 'root' level"
        }
        # Reachability from root along child edges. A rule at a level the
        # walk can never reach would be selected, paid for, and silently
        # never evaluated - a counterfeit pass, refused at compile.
        if {[llength $StageRules]} {
            set reach [dict create root 1]
            set grow 1
            while {$grow} {
                set grow 0
                foreach edge $StageChildren {
                    lassign $edge parent key mode child
                    if {[dict exists $reach $parent] && ![dict exists $reach $child]} {
                        dict set reach $child 1
                        set grow 1
                    }
                }
            }
            foreach r $StageRules {
                if {![dict exists $reach [dict get $r level]]} {
                    throw [list YAMLMUSTER LOAD $label 0] \
                        "yamlmuster: rules '$label': rule '[dict get $r code]': level '[dict get $r level]' is not reachable from root"
                }
            }
        }

        set levels [dict create]
        dict for {name keys} $StageLevels {
            dict set levels $name keys $keys
            dict set levels $name children [dict create]
        }
        foreach edge $StageChildren {
            lassign $edge parent key mode child
            dict set levels $parent children $key \
                [dict create mode $mode level $child]
        }
        set owners [dict create]
        dict for {name keys} $StageLevels {
            foreach k $keys { dict lappend owners $k $name }
        }
        set bylevel [dict create]
        set rules {}
        set id 0
        foreach r $StageRules {
            dict set r id $id
            lappend rules $r
            dict lappend bylevel [dict get $r level] $id
            incr id
        }
        set parents [dict create]
        foreach edge $StageChildren {
            lassign $edge parent key mode child
            if {$parent ni [dict getdef $parents $child {}]} {
                dict lappend parents $child $parent
            }
        }
        set groups [dict create]
        foreach r $rules {
            foreach g [dict get $r groups] { dict set groups $g 1 }
        }

        set DeclLevels $StageLevels
        set DeclChildren $StageChildren
        set Rules $rules
        set Levels $levels
        set KeyOwners $owners
        set ByLevel $bylevel
        set Parents $parents
        set Groups $groups
        return
    }

    # -- validation -------------------------------------------------------

    method validate {data args} {
        if {[llength $args] % 2} {
            throw {YAMLMUSTER OPTION validate} \
                "yamlmuster: validate options must be option-value pairs"
        }
        set groupsF {}; set sevF {error warning}; set context {}
        set extra {}; set limit 0; set badnode issue
        foreach {o v} $args {
            switch -- $o {
                -groups     { set groupsF $v }
                -severities { set sevF $v }
                -context    { set context $v }
                -extra      { set extra $v }
                -limit      { set limit $v }
                -badnode    { set badnode $v }
                default     {
                    throw [list YAMLMUSTER OPTION $o] \
                        "yamlmuster: unknown option '$o' to validate"
                }
            }
        }
        foreach g $groupsF {
            # A group no rule carries would validate nothing and look like
            # a pass; refuse it instead.
            if {![dict exists $Groups $g]} {
                throw [list YAMLMUSTER GROUP $g] "yamlmuster: unknown group '$g'"
            }
        }
        foreach s $sevF {
            if {$s ni {error warning}} {
                throw [list YAMLMUSTER SEVERITY $s] \
                    "yamlmuster: unknown severity '$s'"
            }
        }
        if {![string is integer -strict $limit] || $limit < 0} {
            throw {YAMLMUSTER OPTION -limit} \
                "yamlmuster: -limit must be a non-negative integer"
        }
        if {$badnode ni {issue ignore}} {
            throw {YAMLMUSTER OPTION -badnode} \
                "yamlmuster: -badnode must be issue or ignore"
        }
        if {[llength $context] % 2} {
            throw {YAMLMUSTER OPTION -context} \
                "yamlmuster: -context must be a name-value list"
        }
        if {[llength $extra] % 2} {
            throw {YAMLMUSTER OPTION -extra} \
                "yamlmuster: -extra must be a key-value list"
        }

        # Pre-traversal selection: groups, declared severity, needs. Each
        # deselection costs one lookup here and nothing during the walk.
        set skipped 0
        set WSelected [dict create]
        foreach r $Rules {
            if {[llength $groupsF]} {
                set hit 0
                foreach g [dict get $r groups] {
                    if {$g in $groupsF} { set hit 1; break }
                }
                if {!$hit} continue
            }
            if {[dict get $r severity] ni $sevF} continue
            set drop 0
            foreach n [dict get $r needs] {
                if {![dict exists $context $n]} { set drop 1; break }
            }
            if {$drop} { incr skipped; continue }
            dict set WSelected [dict get $r id] 1
        }
        if {![dict size $WSelected]} {
            set Stats [my ZeroStats]
            dict set Stats rules_skipped_needs $skipped
            return {}
        }

        # Levels the walk must enter: those holding selected rules, plus
        # every ancestor on a path from root (fixpoint over the reverse
        # edges; level counts are single digits, cycles converge).
        set WNeeded [dict create]
        dict for {rid v} $WSelected {
            dict set WNeeded [dict get [lindex $Rules $rid] level] 1
        }
        set grow 1
        while {$grow} {
            set grow 0
            foreach lvl [dict keys $WNeeded] {
                foreach p [dict getdef $Parents $lvl {}] {
                    if {![dict exists $WNeeded $p]} {
                        dict set WNeeded $p 1
                        set grow 1
                    }
                }
            }
        }

        set WIssues {}
        set WContext $context
        set WExtra $extra
        set WLimit $limit
        set WBadnode $badnode
        set WEvaluated 0
        set WVisited 0
        set WErrors 0
        try {
            my Walk $data root {}
        } trap {YAMLMUSTER _LIMIT} {} {}
        set Stats [dict create \
            rules_selected [dict size $WSelected] \
            rules_evaluated $WEvaluated \
            rules_skipped_needs $skipped \
            nodes_visited $WVisited \
            issues_emitted [llength $WIssues] \
            errors_emitted $WErrors]
        return $WIssues
    }

    # Last validate's cost account. All zeros before the first call.
    method stats {} {
        return $Stats
    }

    # Introspection: enough for a caller's --help and for the tests.
    # `rules` reports vocab rules under the placeholder code `vocab`.
    method info {what} {
        switch -- $what {
            groups  { return [lsort [dict keys $Groups]] }
            levels  { return [dict keys $Levels] }
            rules   { return [dict create count [llength $Rules] \
                          codes [lmap r $Rules {dict get $r code}]] }
            default {
                throw [list YAMLMUSTER OPTION $what] \
                    "yamlmuster: info expects groups, levels, or rules"
            }
        }
    }

    # -- the walk ---------------------------------------------------------

    method Walk {node level path} {
        # A node that is not a key-value list: one bad_node issue (or a
        # silent skip under -badnode ignore), rules and descent pruned.
        if {[catch {llength $node} n] || $n % 2} {
            my BadNode $path $level
            return
        }
        incr WVisited
        foreach rid [dict getdef $ByLevel $level {}] {
            if {![dict exists $WSelected $rid]} continue
            my EvalRule [lindex $Rules $rid] $node $path
        }
        dict for {key spec} [dict get $Levels $level children] {
            set clevel [dict get $spec level]
            if {![dict exists $WNeeded $clevel]} continue
            if {![dict exists $node $key]} continue
            set val [dict get $node $key]
            if {[dict get $spec mode] eq "dict"} {
                my Walk $val $clevel [list {*}$path $key]
            } else {
                if {[catch {llength $val} len]} {
                    my BadNode [list {*}$path $key] $clevel
                    continue
                }
                for {set i 0} {$i < $len} {incr i} {
                    my Walk [lindex $val $i] $clevel [list {*}$path $key $i]
                }
            }
        }
        return
    }

    method BadNode {path level} {
        if {$WBadnode eq "ignore"} return
        set where [expr {[llength $path] ? [join $path { }] : "root"}]
        my Emit [dict create severity error code bad_node \
            message "value at $where is not a dict: odd or unbalanced key-value list" \
            path $path level $level]
        return
    }

    # Compose and record one issue: -extra first, engine fields over it,
    # so severity/code/message/path/level/key always win a collision.
    # Error-severity issues count toward -limit; hitting it unwinds the
    # walk through the _LIMIT throw validate traps.
    method Emit {fields} {
        set issue [dict remove $WExtra severity code message path level key owner]
        dict for {k v} $fields { dict set issue $k $v }
        lappend WIssues $issue
        if {[dict get $fields severity] eq "error"} {
            incr WErrors
            if {$WLimit > 0 && $WErrors >= $WLimit} {
                throw {YAMLMUSTER _LIMIT} limit
            }
        }
        return
    }

    method EvalRule {rule node path} {
        incr WEvaluated
        foreach {k v} [dict get $rule when] {
            if {![dict exists $node $k] || [dict get $node $k] ne $v} return
        }
        foreach {k v} [dict get $rule unless] {
            if {[dict exists $node $k] && [dict get $node $k] eq $v} return
        }
        set level [dict get $rule level]
        set sev [dict get $rule severity]
        set code [dict get $rule code]
        set tmpl [dict get $rule message]
        set params [dict get $rule params]
        switch -- [dict get $rule kind] {
            vocab {
                set known [dict get $Levels $level keys]
                foreach {k v} $node {
                    if {$k in $known} continue
                    set owners {}
                    foreach o [dict getdef $KeyOwners $k {}] {
                        if {$o ne $level} { lappend owners $o }
                    }
                    if {[llength $owners]} {
                        # owner: the first-declared level owning the key,
                        # exposed so a consumer can compose its own words.
                        my Emit [dict create severity $sev code wrong_level \
                            message "'$k' at $level belongs at [lindex $owners 0]; move it there" \
                            path $path level $level key $k \
                            owner [lindex $owners 0]]
                    } else {
                        my Emit [dict create severity $sev code unknown_key \
                            message "unknown key '$k' at $level" \
                            path $path level $level key $k]
                    }
                }
            }
            require {
                set kp [dict get $params keypath]
                if {[dict get $params anyof]} {
                    set ok 0
                    foreach k $kp {
                        if {[my PathOK $node [list $k] $params]} {
                            set ok 1
                            break
                        }
                    }
                } else {
                    set ok [my PathOK $node $kp $params]
                }
                if {!$ok} {
                    set kdisp [join $kp .]
                    set what missing
                    if {[dict get $params nonblank]} { set what "missing or blank" }
                    if {[dict get $params nonempty]} { set what "missing or empty" }
                    if {[dict get $params anyof]} {
                        set def "none of {$kp} usable at $level"
                    } else {
                        set def "required '$kdisp' $what at $level"
                    }
                    my Emit [dict create severity $sev code $code \
                        message [my Msg $tmpl $def $kdisp "" $path ""] \
                        path $path level $level key $kp]
                }
            }
            oneof {
                set kp [dict get $params keypath]
                lassign [my GetVal $node $kp] present val
                if {$present && $val ni [dict get $params values]} {
                    set kdisp [join $kp .]
                    set def "'$val' at '$kdisp' is not one of {[dict get $params values]}"
                    my Emit [dict create severity $sev code $code \
                        message [my Msg $tmpl $def $kdisp $val $path ""] \
                        path $path level $level key $kp]
                }
            }
            length {
                set kp [dict get $params keypath]
                lassign [my GetVal $node $kp] present val
                if {$present} {
                    if {[dict get $params trim]} { set val [string trim $val] }
                    set n [string length $val]
                    set max [dict get $params max]
                    set min [dict get $params min]
                    set def ""
                    if {$n > $max} {
                        set def "length of '[join $kp .]' is $n, over the maximum $max"
                    } elseif {$min ne "" && $n < $min} {
                        set def "length of '[join $kp .]' is $n, under the minimum $min"
                    }
                    if {$def ne ""} {
                        my Emit [dict create severity $sev code $code \
                            message [my Msg $tmpl $def [join $kp .] $val $path $n] \
                            path $path level $level key $kp]
                    }
                }
            }
            regexp {
                set kp [dict get $params keypath]
                lassign [my GetVal $node $kp] present val
                if {$present && ![regexp -- [dict get $params re] $val]} {
                    set kdisp [join $kp .]
                    set def "'$val' does not match the pattern required at '$kdisp'"
                    my Emit [dict create severity $sev code $code \
                        message [my Msg $tmpl $def $kdisp $val $path ""] \
                        path $path level $level key $kp]
                }
            }
            range {
                set kp [dict get $params keypath]
                lassign [my GetVal $node $kp] present val
                if {$present} {
                    set val [string trim $val]
                    set kdisp [join $kp .]
                    set min [dict get $params min]
                    set max [dict get $params max]
                    set def ""
                    if {[dict get $params integer] && ![string is integer -strict $val]} {
                        set def "'$val' at '$kdisp' is not an integer"
                    } elseif {![string is double -strict $val]} {
                        set def "'$val' at '$kdisp' is not a number"
                    } elseif {$min ne "" && $val < $min} {
                        set def "'$val' at '$kdisp' is under the minimum $min"
                    } elseif {$max ne "" && $val > $max} {
                        set def "'$val' at '$kdisp' is over the maximum $max"
                    }
                    if {$def ne ""} {
                        my Emit [dict create severity $sev code $code \
                            message [my Msg $tmpl $def $kdisp $val $path ""] \
                            path $path level $level key $kp]
                    }
                }
            }
            any {
                set listkey [dict get $params listkey]
                if {[dict exists $node $listkey]} {
                    set lst [dict get $node $listkey]
                    set found 0
                    if {![catch {llength $lst}]} {
                        foreach elem $lst {
                            if {[my MatchWhere $elem [dict get $params where]]} {
                                set found 1
                                break
                            }
                        }
                    }
                    if {!$found} {
                        set def "no element of '$listkey' matches {[dict get $params where]}"
                        my Emit [dict create severity $sev code $code \
                            message [my Msg $tmpl $def $listkey "" $path ""] \
                            path $path level $level key $listkey]
                    }
                }
            }
            atmost {
                set listkey [dict get $params listkey]
                if {[dict exists $node $listkey]} {
                    set lst [dict get $node $listkey]
                    set count 0
                    if {![catch {llength $lst}]} {
                        foreach elem $lst {
                            if {[my MatchWhere $elem [dict get $params where]]} {
                                incr count
                            }
                        }
                    }
                    set cap [dict get $params n]
                    if {$count > $cap} {
                        set def "'$listkey' has $count matching elements; at most $cap allowed"
                        my Emit [dict create severity $sev code $code \
                            message [my Msg $tmpl $def $listkey "" $path $count] \
                            path $path level $level key $listkey]
                    }
                }
            }
            predicate {
                set name [dict get $params name]
                set meta [dict create path $path level $level \
                    context $WContext extra $WExtra]
                if {[catch {{*}[dict get $Preds $name] $node $meta} out]} {
                    # A throwing predicate is a host bug, not an issue.
                    throw [list YAMLMUSTER PREDICATE $name] \
                        "yamlmuster: predicate '$name' (rule $code): $out"
                }
                foreach partial $out {
                    if {[catch {dict size $partial}]} {
                        throw [list YAMLMUSTER PREDICATE $name] \
                            "yamlmuster: predicate '$name' (rule $code): returned a non-dict issue"
                    }
                    # Engine fills severity/code from the declaration and
                    # owns path/level; the predicate may override
                    # severity, code, and message per issue.
                    set fields $partial
                    dict set fields severity [dict getdef $partial severity $sev]
                    dict set fields code [dict getdef $partial code $code]
                    dict set fields message [dict getdef $partial message \
                        [my Msg $tmpl "flagged by predicate '$name'" "" "" $path ""]]
                    dict set fields path $path
                    dict set fields level $level
                    my Emit $fields
                }
            }
        }
        return
    }

    # -- small helpers ----------------------------------------------------

    # Walk a nested keypath with odd-length guards: an intermediate value
    # that is not a dict counts as absent.
    method PathOK {node kp params} {
        set cur $node
        foreach k $kp {
            if {[catch {dict exists $cur $k} has] || !$has} { return 0 }
            set cur [dict get $cur $k]
        }
        if {[dict get $params nonblank] && [string trim $cur] eq ""} {
            return 0
        }
        if {[dict get $params nonempty] \
                && ([catch {llength $cur} n] || $n == 0)} {
            return 0
        }
        return 1
    }

    # Value fetch for the value-testing kinds (oneof/length/regexp/range):
    # absent and blank both read as "no value" - presence and blankness
    # are require's business, so these kinds never double-report it.
    method GetVal {node kp} {
        set cur $node
        foreach k $kp {
            if {[catch {dict exists $cur $k} has] || !$has} { return {0 {}} }
            set cur [dict get $cur $k]
        }
        if {[string trim $cur] eq ""} { return {0 {}} }
        return [list 1 $cur]
    }

    # Element match for any/atmost: every -where pair present and equal.
    # An empty pair list matches every element; a non-dict element none.
    method MatchWhere {elem pairs} {
        if {[catch {llength $elem} n] || $n % 2} { return 0 }
        foreach {k v} $pairs {
            if {![dict exists $elem $k] || [dict get $elem $k] ne $v} {
                return 0
            }
        }
        return 1
    }

    # A rule's -message template replaces the default whole; %k the key,
    # %v the value, %p the path, %n the measured number.
    method Msg {tmpl def key value path n} {
        if {$tmpl eq ""} { return $def }
        set p [expr {[llength $path] ? [join $path { }] : "root"}]
        return [string map [list %k $key %v $value %p $p %n $n] $tmpl]
    }

    method ZeroStats {} {
        return [dict create rules_selected 0 rules_evaluated 0 \
            rules_skipped_needs 0 nodes_visited 0 \
            issues_emitted 0 errors_emitted 0]
    }
}
