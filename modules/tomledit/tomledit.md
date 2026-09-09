# tomledit

## NAME

tomledit - TOML edits that change one key's bytes and no others

## SYNOPSIS

```tcl
package require tomledit

set text [tomledit::read_file $path]
if {[set what [tomledit::unsafe $text]] ne ""} {
    error "not editing $path: $what"
}
set text [tomledit::put $text screen.bloom [tomledit::format_value float 0.4]]
tomledit::atomic_write $path $text
```

## DESCRIPTION

A tool writing into a config file the user also edits by hand faces a file that is not its own: hand-written comments, blank-line rhythm, odd spacing, keys some other tool owns. A parse-and-reserialize round trip rewrites all of it to say one new value, and the user's file stops being theirs. tomledit works on the file's raw lines instead. A writer that changes one key changes only that key's bytes, and every edit is provably that narrow: diff the before and after and one line moves.

The addressing is DOM-like; the materialisation deliberately is not. A path resolves to a span of lines in the text, never to a tree that would be re-serialised. `screen.bloom` names key `bloom` of table `[screen]`; `ssh.host[1].port` names key `port` of the second `[[ssh.host]]` row; `ssh.host[1]` names that row itself. The last dot splits table from key, which is unambiguous because the subset refuses dotted keys, and a table's own name may carry dots (`ssh.host` rows hang under `[ssh]`).

The subset is flat scalar values in named tables, plus two shapes of row. An array of tables (`[[name]]`) has rows that are themselves flat, so a row is a span of lines and a row's key is a scalar inside that span. An inline-row array is a key whose value opens `[` on its own line, holds one inline table per line, and closes on a line of `]`:

```toml
[bindings]
keys = [
  { key = "b", with = "ctrl | shift", action = "fold_bank" },
  { key = "c", with = "ctrl | shift", action = "pass" },
]
```

There a row is the span of one line and a row's key is a scalar inside the braces; `bindings.keys[1].action` names `action` of the second row, `bindings.keys[1]` that row, and a blank or comment line between rows is kept and is not a row. Values travel as raw TOML text - quoting intact - so an edited value can be formatted after the type of the value it replaces (`type_of`, `format_value`) and unquoted only where displayed (`plain`).

A document using TOML beyond the subset (multiline strings, dotted keys, an inline table as a plain value, a multiline array of anything but inline-table rows) can fool a line-oriented span finder: a multiline string may hold a line shaped like a header, and an edit would land inside the string. A writer therefore asks `unsafe` first and refuses rather than guessing. A refused edit costs the caller's user a hand edit; a misplaced one costs them their file.

What survives an edit, byte for byte: leading whitespace and the `key = ` spelling of an edited line, its trailing same-line comment, every other line's bytes, the presence or absence of a trailing newline. A new key lands at the end of its table's span, above the blank padding and above a comment block introducing the next table. Deleting the last key of a table keeps the header: an empty table means the same as an absent one, and the header may carry a comment.

## COMMANDS

Paths:

**tomledit::get** *text path* ?*fallback*?
: The raw value the path names, or *fallback* (default `{}`) when the table, row or key is absent.

**tomledit::put** *text path value*
: Set what the path names to the pre-formatted TOML scalar *value*, touching only that key's bytes. An absent key is appended inside its table or row (as the last pair of an inline row); an absent table is appended at EOF. A row index naming no row is an error, not a guess.

**tomledit::del** *text path*
: Remove what the path names: a key's line or pair (`t.k`, `a[i].k`; absent is a byte-for-byte no-op; the last pair of an inline row is an error, since a row holding no key names nothing) or a whole row (`a[i]`; absent is an error). Removing a `[[name]]` row leaves a comment block that introduces the next header; removing an inline row takes its line alone.

**tomledit::add** *text name kvlist* ?*shape*?
: A new row of *name* carrying *kvlist* (flat key/pre-formatted-value list), in the shape the document already gives *name*. A `[[name]]` row goes after the last row, or after the parent table (`ssh.host` hangs under `[ssh]`) when there are no rows yet, or at EOF. An inline row goes on the line above the closing `]`, indented as the last row is; a last row lacking its trailing comma gains one, the one edit outside the new line that TOML requires. *shape*, `header` (the default) or `inline`, decides only for an array the document does not yet hold; `inline` opens `key = [` and `]` at the end of the parent table's span, writing the table too when the document lacks it.

**tomledit::count** *text name*
: How many rows *name* holds, of either shape.

**tomledit::ensure_table** *text table* ?*above*?
: Give the table a header if it has none. *above* names an array of tables whose rows the table heads; when rows exist the header goes above the first of them.

Reading:

**tomledit::parse** *text*
: The document as a dict: `tables` maps each table name to a dict of key to raw value; `arrays` maps each `[[name]]`, and each inline-row array as `table.key`, to a list of such dicts, one per row in declaration order. An inline-row array is not among its table's values. Other multi-line array values are joined onto one line first.

**tomledit::unsafe** *text*
: Empty when the document sits inside the subset the line surgery understands; otherwise one line naming what falls outside and where. Ask before writing.

Values:

**tomledit::type_of** *raw*
: `string`, `bool`, `int` or `float`, from the raw spelling.

**tomledit::format_value** *type value*
: A plain Tcl value as a raw TOML scalar of that type. Floats always carry a decimal point.

**tomledit::plain** *raw*
: The unquoted Tcl value of a raw scalar. A literal string keeps its bytes; only a basic string carries escapes to undo.

Files:

**tomledit::read_file** *path*
: The whole file as text (UTF-8); a missing file is the empty document.

**tomledit::atomic_write** *path text*
: Write-temp-then-rename in the file's own directory, so a live watcher of the file never sees it half written and the rename fires exactly one change.

## EXAMPLE

```tcl
package require tomledit

set before {# mine, hands off
[screen]
bloom   =   0.9	# cranked
}
set after [tomledit::put $before screen.bloom 0.4]
;# => same bytes, except the one line now reads: bloom   =   0.4	# cranked
```

## LICENSE

MIT.
