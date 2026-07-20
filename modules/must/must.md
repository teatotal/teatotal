# must

## NAME

must - the substring a regular expression cannot match without

## SYNOPSIS

```tcl
package require must

set keep [must::filter $pattern]
foreach line $lines {
    if {![{*}$keep $line]} continue        ;# provably no match: skip
    if {[regexp -- $pattern $line]} { ... } ;# factor present: verify
}

lassign [must::factor {[^A-Za-z]M2[^A-Za-z]}] factor nocase
;# factor = M2, nocase = 0
```

## DESCRIPTION

A regular expression run over bulk text spends most of its work proving haystacks irrelevant. A plain substring scan proves the same thing far more cheaply whenever some literal is known to appear in every match. GNU grep derives such a string (its dfamust) and skips with Boyer-Moore; ripgrep feeds its literals to a prefilter; Hyperscan matches literal factors before waking its automata; a trigram index answers the question per document instead of per line.

must is that idea for one Tcl proc. From an Advanced Regular Expression it derives a factor - a substring every match must contain - so a caller gates lines, files, or index lookups with `string first` and runs the regex only where the factor appears.

The contract is one-sided: a factor is necessary, never sufficient. A haystack holding the factor may still not match; a haystack without it cannot. That asymmetry is the whole value, a cheap test that never rejects a real match, only the haystacks that could not have held one.

The extractor reads the pattern string alone. It forfeits - returns no factor - on any construct it does not fully model: a `***` director, a `(?...)` group past the start (options, non-capturing, lookahead), a leading `(?...)` block carrying the expanded, quoted, or Basic-RE (BRE) letters, a variable-length escape (hex `\xhh`, Unicode `\uwxyz` and `\Ustuvwxyz`, control `\cX`, an octal, or a multi-digit backreference), an alternation outside any group, an opening brace that never closes its bound, and a pattern regexp itself rejects. A forfeit costs pruning, never correctness: with no factor every haystack stays a candidate. A factor's pruning power is only as good as the factor is rare, so a one-character factor gates little.

The factor is a substring of the match text itself. A caller gating a transformed representation of that text - an escaped, encoded, or wrapped form - owns the question of whether its transform preserves the factor's characters.

## COMMANDS

**must::factor** ?*-nocase*? ?*-expanded*? *pattern*
: The required factor and its case mode, as `{factor nocase}`; `{"" 0}` when none can be soundly extracted. `nocase 1` (a leading `(?i)`, or the `-nocase` option) means the factor comes back lowered and must be sought in a lowered haystack.

**must::filter** ?*-nocase*? ?*-expanded*? *pattern*
: A test command prefix: `[{*}$cmd $haystack]` is 0 only when the missing factor proves the haystack holds no match, 1 otherwise. A factor-less pattern yields the always-1 command, so a skip loop stays sound with no branch on extractability. A malformed pattern also merely forfeits: the filter passes everything and the caller's own `regexp` raises the error at the match site.

## MIRRORING THE MATCH FLAGS

The extractor sees the pattern string, and regexp's command-line flags change what a pattern means, so pass must the flags you match with. A caller running `regexp -nocase` passes `-nocase` here (or embeds `(?i)`); one running `regexp -expanded` passes `-expanded`, which forfeits the factor as an in-pattern `(?x)` does. Gating a `-nocase` match with an unflagged, case-exact factor is a silent-loss trap: the factor tests case-exactly, regexp matches case-blind, and the differing haystacks are wrongly skipped. The newline flags (`-line` and kin) need no mirroring; they move what `^ $ .` mean, never what a literal run requires.

## REQUIREMENTS

Tcl 9. No Tk, no dependencies.

## KEYWORDS

regexp, prefilter, literal, substring, factor, grep, scan, filter
