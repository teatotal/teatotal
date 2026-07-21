# yamlmuster

## NAME

yamlmuster - a rule-indexed validator for parsed YAML: partial validation that bills only the checks you select, and policed rule loading from a rules file that can only declare

## SYNOPSIS

```tcl
package require yamlmuster

set v [yamlmuster new]
$v predicate fresh ::myapp::check_fresh      ;# host escape hatch
$v load {
    level root  -keys {version rounds}
    level round -keys {type number}
    child root rounds list round
    rule oneof root version {1.0} -code version_unsupported
    rule require root rounds -nonempty -code missing_rounds -groups shape
    rule any root rounds -where {type final} -code no_final_round -groups shape
    rule predicate round fresh -code stale_round -needs today
} -name campaign

set issues [$v validate $data -groups shape -limit 1]
$v stats                                     ;# what that pass paid
```

## DESCRIPTION

yamlmuster validates dicts against rules, with two properties its name-brand competitors - the hand-grown one-proc-per-file-shape validators - do not have. **Partial validation**: rules are indexed by level, group tag, and severity, a validate call selects before it walks, and only the subtrees holding selected rules are entered, so you pay for the checks you asked for and `stats` shows the bill. **Policed rule loading**: the rules script is evaluated in an interpreter whose entire command table is `level`, `child`, and `rule`, so a rules file can declare and do nothing else - `exec ls` in one dies at load, with its line number, and leaves the previous ruleset untouched.

yamlmuster is dict-in: it never parses YAML. A parser - tcllib's yaml, for the programs this grew in - turns the file into a Tcl dict, and yamlmuster validates the dict. The verified compatibility level is measured, parser version and exclusions named, in YAML COMPATIBILITY below; the name promises no more than the parser feeding it delivers.

The validator does no I/O anywhere: the host reads the rules file and the data file, yamlmuster sees only strings and dicts. One instance carries one ruleset; a program validating several document kinds holds one instance per kind.

## THE RULES FILE

Three verbs, flat, no script bodies. Loads are additive across calls and atomic per call: declarations stage into a copy, the compile runs over the union, and only a fully compiled index swaps in - any error, in the script or the compile, leaves the previous ruleset as it was.

**level** *name* **-keys** *{k ...}*
: Declare a level and its closed vocabulary. The level named exactly `root` is the traversal entry; a load that declares rules but no `root` level fails at compile. Redeclaring a level errors, in the same load or a later one.

**child** *parent* *key* **dict**|**list** *childlevel*
: A nesting edge: at *parent*, *key* holds one *childlevel* dict, or a list of them. Forward references resolve at end-of-load compile, which also rejects undeclared levels, duplicate edges, and rules at levels unreachable from `root` (an unreachable rule would be selected, paid for, and never run - a counterfeit pass). This one declaration drives both the `wrong_level` hints and the traversal pruning.

**rule** *kind* *level* *kind-args ...* ?*options*?
: A check attached to a level, evaluated at every node of that level the walk reaches. Common options:

**-code** *token*
: The machine token every issue from this rule carries. Required for every kind except `vocab`, which emits the built-in codes `unknown_key` and `wrong_level` and accepts no `-code`.

**-severity** **error**|**warning**
: Static per rule; default `error`. What `-severities` filters on.

**-groups** *{tag ...}*
: Selection tags. A rule with no tags runs only in unfiltered (no `-groups`) validates.

**-when** *{field value ...}*
: AND-list of equality gates on sibling fields of the same node; the rule skips silently when any pair fails or its field is absent.

**-unless** *{field value ...}*
: Skip when any pair matches - the negation `-when` cannot say.

**-needs** *{name ...}*
: Context names. A need absent from the validate call's `-context` drops the rule pre-traversal, counted in `rules_skipped_needs`.

**-message** *text*
: Replaces the kind's default message whole. `%k` the key, `%v` the value, `%p` the path, `%n` the measured number.

## RULE KINDS

**vocab**
: Every key of the node must be in the level's `-keys`. A stray key that is canonical at another level emits `wrong_level`, its message and `owner` field naming the first-declared owning level; otherwise `unknown_key`. Both carry `key` and `level`.

**require** *keypath* ?**-anyof**? ?**-nonblank**? ?**-nonempty**?
: The keypath (a list, walked into nested dicts with odd-length guards) must resolve. `-nonblank` also refuses a whitespace-only value, and a missing intermediate key counts as blank; `-nonempty` refuses an empty list. With `-anyof` the keypath reads as single-key alternatives and any one present (and passing the modifiers) satisfies.

**oneof** *keypath* *{v1 v2 ...}*
: A present, non-blank value must be in the set. Absence is require's business.

**length** *keypath* **-max** *n* ?**-min** *n*? ?**-trim**?
: String length bounds on a present, non-blank value; `-trim` measures the trimmed value.

**regexp** *keypath* *re*
: A present, non-blank value must match. The pattern is compiled at load; a bad one is a load error.

**range** *keypath* ?**-min** *n*? ?**-max** *n*? ?**-integer**?
: Numeric bounds on a present, non-blank value; at least one option is required. A non-numeric value is itself the issue (`-integer` demands an integer; bounds alone demand a number).

**any** *listkey* **-where** *{field value ...}*
: The list at *listkey* must hold at least one element matching every `-where` pair. An absent *listkey* skips; an empty or unreadable list fails.

**atmost** *listkey* *n* ?**-where** *{field value ...}*?
: At most *n* elements match (all elements, without `-where`). `%n` in a message is the measured count.

**any** and **atmost** read list elements shallowly from the parent level; they are rules at that level and do not force descent.

**predicate** *name*
: The escape hatch: a host command registered under *name* before the load (an unregistered name is a load error). Called as `{*}cmdprefix node meta` with meta `{path ... level ... context ... extra ...}`; returns a list of partial issue dicts, empty for a pass. The validator fills `severity` and `code` from the declaration and owns `path` and `level`; a partial issue may override severity, code, and message, which is how one predicate emits two codes. A predicate that throws is a host bug: validate rethrows it as `yamlmuster: predicate '<name>' (rule <code>): ...`, never an issue.

## THE POLICED INTERPRETER

Each load evaluates the rules script in a fresh `interp create -safe` child that is then stripped: `::oo` is deleted while `namespace` is still alive (a safe interp ships TclOO, reachable by qualified name), every exposed global command is hidden, and `::tcl` is deleted through the hidden `namespace` - removing `::tcl::mathfunc` and `::tcl::mathop` too. What remains resolvable is exactly the three aliases, each bound to a registration-only method in the host object; the tests assert the containment against `set`, `exec`, `open`, `source`, `package require`, `eval`, `interp create`, and `while`. The child is deleted after the eval; no state crosses loads.

Comments and line continuations are parse-level and survive; an empty or comment-only script loads to zero rules. Any other command dies as `invalid command name`, and every load error is rethrown as `yamlmuster: rules '<label>' line <n>: ...` with `-errorcode {YAMLMUSTER LOAD <label> <n>}` (`<label>` from load's `-name`, default `rules`; line 0 for end-of-load compile errors, which have no script line).

## VALIDATION

**$v validate** *data* ?**-groups** *{g ...}*? ?**-severities** *{error|warning ...}*? ?**-context** *{name val ...}*? ?**-extra** *{k v ...}*? ?**-limit** *n*? ?**-badnode** **issue**|**ignore**?
: Returns a list of issue dicts.

**-groups**
: Select rules carrying any listed tag; omitted, every rule. A group no rule carries errors at once (`{YAMLMUSTER GROUP <name>}`) - silently validating nothing would counterfeit a pass.

**-severities**
: Pre-traversal filter on declared severity; default `{error warning}`. Skipped warning rules cost nothing and are absent from `rules_selected`.

**-context**
: Named external facts for `-needs` and predicates. A superset is fine; names no rule asks for sit unused.

**-extra**
: Merged into every emitted issue - where a consumer stamps `contact_name` or `segment` without teaching the validator its vocabulary. Validator keys (`severity code message path level key owner`) win a collision.

**-limit** *n*
: Stop after *n* error-severity issues; warnings do not count. 0 or omitted is unlimited. `-limit 1` is a transition gate.

**-badnode**
: A node that is not a key-value list (odd length, or unbalanced) emits one `bad_node` error with its path and prunes that subtree; `ignore` skips it silently instead (default `issue`). A root that is not a dict yields a single `bad_node` and nothing else.

Each issue carries `severity`, `code`, `message`, `path` (the key/index trail from root, `{rounds 2 messages 0}`), `level`, `key` where one exists (vocab, require, oneof, length, regexp, range, any, atmost), `owner` on `wrong_level`, and every `-extra` pair.

The cost model: selection happens before traversal - groups, declared severity, and needs each cost a deselected rule one lookup - then the walk enters only the levels holding selected rules and their ancestors, so unpaid subtrees are never visited. Evaluation order is deterministic: at each node, rules in declaration order; then child edges in declaration order; list elements in data order. `-limit 1` returns the same first error every run.

## PREDICATES AND CONTEXT

**$v predicate** *name* *cmdprefix*
: Register a host predicate; must precede any load naming it, and re-registering a name errors. Everything effectful a predicate wants - file hashes, roster lookups, today's date - arrives through `-context` and the host command itself; pair `-needs` with the context names so an un-supplied fact drops the rule, visibly, instead of crashing it.

## STATS

**$v stats**
: The last validate's cost account, all zeros before the first: `rules_selected` (survivors of the group, severity, and needs filters), `rules_evaluated` (rule-at-node evaluations, `-when`/`-unless` gate checks included), `rules_skipped_needs`, `nodes_visited`, `issues_emitted`, `errors_emitted`. This is the tested face of the partial-validation claim: the suite asserts a root-only group visits one node of a 181-node document.

**$v info** **groups**|**levels**|**rules**
: Introspection: the known group tags (sorted), the declared levels (declaration order), and `{count n codes {...}}` for the compiled rules - enough for a caller's `--help`. `vocab` rules report the placeholder code `vocab`; their emitted codes are `unknown_key` and `wrong_level`.

## YAML COMPATIBILITY

yamlmuster is dict-in; YAML support is inherited from the parser feeding it. Verified level: YAML 1.1 as parsed by tcllib yaml 0.4.2, checked class-by-class in tests/test-yamlmuster-yaml.tcl - block scalars with all three chompings, folded scalars, the three scalar styles, nested block and flow collections, anchors with backward aliases, merge keys, and `!!str` pinning all arrive as the dicts the tests assert.

Named exclusions (measured): forward alias references and tags outside the `!!` core raise plain errors (empty `-errorcode`); lines beginning `#` inside block scalars are dropped by the parser - content loss, not an error; tabs in plain scalars raise; and a document whose last line is `key:` with no trailing newline never returns - the parser loops, so feed it whole files ending in a newline, or run it under an interp time limit as the corpus test does.

Named transformations: YAML 1.1 boolean coercions (`yes/no/y/n/on/off/+/-` arrive as `1`/`0` - the Norway problem, a bare `-` included), `null`/`~`/empty as `""`, comma-grouped integers with the commas stripped (nonstandard), and unquoted ISO dates as epoch seconds. They arrive already transformed, before any rule runs: a `oneof` over `{yes no}` fires on `enabled: yes` because the value is `1`. Pin with `!!str` or quotes where the literal text matters.

## NOTES

At each node the walk runs all of the node's rules, then descends; a validator that makes one pass per concern would emit the same issues in a different cross-depth order. The order here is deterministic, and consumers comparing against another validator's output should compare as multisets.

Value-testing kinds (oneof, length, regexp, range) treat a blank value as absent, so presence and blankness stay require's business and are never double-reported.

`any` and `atmost` never fire on an absent list key - `require` says whether the list must exist.

A predicate registered after a load serves the next load; already-compiled rules are unaffected.

## REQUIREMENTS

Tcl 9. No Tk. tcllib's yaml is used only by the conformance corpus test, which skips without it.

## KEYWORDS

validation, YAML, dict, schema, rules, safe interp, sandbox, partial validation, severity, TclOO
