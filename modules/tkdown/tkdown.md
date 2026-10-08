# tkdown

## NAME

tkdown - a pragmatic markdown renderer for a Tk text widget

## SYNOPSIS

```tcl
::tcl::tm::path add $dir
package require tkdown

text .body
::tkdown::tags .body [dict create \
    body TkTextFont bold myBold italic myItalic bolditalic myBoldItalic \
    mono TkFixedFont]
::tkdown::prose .body end $markdown {base} "\n\n"
```

## DESCRIPTION

Markdown reaches a Tk application constantly, in chat bodies, transcripts, and tool output, and the choices on offer are showing the markers raw or embedding a browser. tkdown is the third: it parses a completed block of markdown into structured segments and inline runs, then paints those onto a `text` widget under the styling tags it owns. The emit half paints fenced code, GFM pipe tables, ATX headings, flat lists, code spans, and asterisk emphasis, and leaves everything else as literal text. Blockquotes are parse-half only: `segment_blockquotes` splits them off, and a host that wants quotes styled paints each de-quoted run itself, under its own tags, because a quote's chrome (bar, indent, ink) is host styling in the same way a code block's is.

The parse half is pure Tcl and needs no Tk, so it runs under a bare `tclsh`; the emit half needs Tk.

## THE HOST OWNS THE CHROME

Every `td-*` tag is either font-only or geometry-only, never coloured. The module owns the faces: it configures `td-bold`, `td-italic`, `td-code`, and the heading levels, each carrying nothing but a `-font`. The geometry tags carry layout and no font: `td-list` the list hanging indent, and `td-tblwin` the margins of the character holding a table's grid, both set from the margin the host names with `-margin`. Colour and selection stay the host's everywhere, a table's included: the host configures `td-grid` with the `-background` its gridlines take and `td-spot` with the one a spotlit table takes, and the module reads them; neither tag is ever laid on text. A caller passes its own base tags into every emit call, and each styled span stacks the module's face over those base tags, so only the typeface changes and the host's ink and layout hold underneath.

That split is why the host, not the module, configures the fonts. `tags` takes a dict of Tk font names the host has already created to match its own reading font, and the module simply binds those names onto its faces. A code block goes in one step further: `body` inserts it under a `codeTags` name the host passes outright, because a code block's margins and background are host chrome, not a tkdown face.

## THE SEGMENT AND INLINE MODEL

The parse half splits a body in layers, each splitter seeing a body the ones above it have already peeled. The block splitters run first, then one prose run at a time goes through the inline pass.

| Proc | Produces | Kinds |
|---|---|---|
| `segment_code_fences` | `{kind text}` | `prose`, `code` (the verbatim run between a pair of fence lines, markers and language tag gone) |
| `segment_blockquotes` | `{kind text}` | `normal`, `quote` (a maximal run of `>` lines, de-quoted one marker deep); parse-half only, the emit walk does not call it |
| `segment_tables` | `{kind payload}` | `normal`, `table` (a parsed GFM pipe table, `{align <per-col> rows <header-then-body>}`) |
| `segment_lists` | `{kind payload}` | `normal`, `list` (a maximal run of `- `/`* `/`N. ` lines; payload is the flat items, each `{num text}`) |
| `parse_inline` | ordered `{style chunk}` runs | `plain`, `code`, `bold`, `italic`, `bolditalic`, markers stripped, adjacent plain runs coalesced |

The inline rules are pragmatic rather than full CommonMark. A code span wins over emphasis, so asterisks inside `` `code` `` stay literal. Emphasis is asterisks only, so `snake_case` and `__init__` are left alone. An opener needs a non-space character after it and a closer one before it, so `3 * 4` and a `* ` bullet marker stay literal. A backslash escapes a literal backtick, asterisk, or backslash, and every other backslash is kept verbatim, so paths and regex survive intact.

## THE EMIT API

Each emit call inserts at an index the caller advances, a mark or `end`, painting in document order.

| Proc | Arguments | Purpose |
|---|---|---|
| `tags` | `w fonts ?option value ...?` | Register a text widget: configure its `td-*` faces from the fonts dict, take the options below, and open its table registry. Call once per widget before painting. |
| `runs` | `w idx text baseTags` | Insert one prose run's inline spans at `idx`. |
| `prose` | `w idx text baseTags {suffix "\n\n"}` | Insert prose plus GFM pipe tables, ATX headings, and flat lists, closed by `suffix`. |
| `body` | `w idx text baseTags codeTags` | Insert a fenced body: prose segments through `prose`, fenced code verbatim under `codeTags`. |
| `refit` | `w ?option value ...?` | Re-set any option, re-derive the margins, and re-fit every built grid. |
| `forget` | `w` | Destroy the widget's grids and unset their marks before a full re-render. |
| `unregister` | `w` | Drop the widget from the registry, its grids with it; runs on the widget's `<Destroy>`. |
| `table_scan` | `w needle nocase` | Search the tables' cell text: `{mark excerpt}` per matching table, in document order. |
| `table_spotlight` | `w idx` | Light the table whose mark is at `idx` and put out the one lit before; `""` puts it out. |

The options, each re-settable through `refit`:

| Option | Default | Meaning |
|---|---|---|
| `-margin` | `{0 0}` | The host's base margin, `{left right}` or one distance for both. `td-list` indents from it, a grid sits at its left edge and spends the width between the two. |
| `-copystyle` | `Copy.TButton` | The ttk style of a grid's copy button. A style ttk has no layout for falls back to `TButton`. |

The fonts dict requires the keys `body`, `bold`, `italic`, `bolditalic`, and `mono`; a missing one is an error, and extra keys are kept but nothing draws with them. The heading keys `h1`, `h2`, and `h3` are optional, each falling back to `bold` when the host leaves it out. ATX heading lines map by their marker count, and four through six `#` all clamp to `h3`, so a document never asks for a face the host did not size.

A flat list renders as one logical line per item: a marker, a tab, then the item text through the inline-run path so markdown inside an item still styles. The marker is a `•` bullet for an unordered item or the item's own number and a dot for an ordered one (`3. ` renders `3.`, the source numbering preserved rather than renumbered). The whole list carries `td-list`, a hanging indent that sets the marker just inside the host's margin and lands the item text, and any line it wraps to, at the tab stop past it; the tag is geometry only, so colour still comes from the base tags.

## THE TABLE AND REFIT LIFECYCLE

A pipe table renders as a grid: one embedded window in the text, a frame of gridded `text` cells that wrap their words. A table wider than the pane keeps its columns and folds its long cells onto more lines, so nothing runs past the right edge. Cells take their font from the fonts dict, the header row bold throughout, and inline markdown inside a cell still styles; each column honours the delimiter's left, right, or centre alignment. A cell's background and cursor are the text widget's, its ink comes from the first base tag carrying a `-foreground` (the widget's own foreground otherwise), and the frame showing through between the cells is the gridline colour, `td-grid`'s `-background` or the widget's foreground when the host configured none.

The window builds itself only when the text first shows it, so a long document costs no widgets until the reader reaches its tables. What search and spotlight need is recorded when the table is painted: the payload, the cells' text as the reader sees it, and a left-gravity mark `tbl#m<N>` on the window character. That character carries `td-tblwin` and the base tags, so a host's fold or elide tag reaches the table like any other text, and it is followed by a blank line under the base tags.

Column widths are fitted to the pane: the room is the widget's inner width less both margins and each column's gridlines and cell padding, every cell's words are measured in the face they paint in, and `table_colwidths` divides the room. A table that fits keeps its natural widths and does not stretch to the pane. Each cell's height follows the width it is given. A grid is fitted once it is built and again, on the next idle pass, whenever the widget is resized or the host calls `refit`; a reading-font change needs `refit`, because the words are measured afresh on every fit.

Under the pointer a grid shows a copy button at its top-right, `-copystyle`'s ttk style, which copies the table to the clipboard as GFM text and shows a tick for a moment; a drag-selection cannot reach into an embedded window, so this is how a reader copies a table. The mouse wheel over a grid scrolls the text widget, with the delta it arrived with.

A text search cannot see into an embedded window either, so the module searches for the host. `table_scan` returns `{mark excerpt}` for each table holding the needle, in document order, the excerpt being the first matching cell's text. The mark is an index like any other: a host's find bar can scroll to it, and `table_spotlight` with the same index paints that table's gridlines in `td-spot`'s `-background`, putting out the table lit before. The spotlight takes effect before the table is built, so a jump that scrolls a table into view for the first time shows it lit.

Before a full re-render, the host calls `forget`: it destroys every grid, unsets every `tbl#m<N>` mark, and empties the registry, so table ids start again from one. A `delete 1.0 end` alone destroys the built grids along with their window characters, and `refit`, `table_scan` and `forget` each drop the record of any table whose window character is gone, but the marks of built grids stay until `forget`. Registration survives `forget`; the registry entry dies with the widget.

## LIMITS

tkdown is not a full CommonMark implementation. Its lists are flat: an indented continuation or a nested marker stays literal, and a host wanting nested lists asks for a block model this renderer keeps deliberately flat. It has no links and no setext (underline) headings; underscores never mark emphasis; anything outside the covered forms renders as literal text. It also takes completed blocks, not a stream: each call paints a finished body in one pass. A host streaming content re-renders the affected block from its own model and repaints it whole.

## REQUIREMENTS

Tcl 9 for the parse half; Tk for the emit half.

## KEYWORDS

markdown, text widget, GFM, tables, rendering, transcript
