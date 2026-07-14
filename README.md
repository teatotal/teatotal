# teatotal

teatotal comes from tea lovers' affection for Tcl and the lamentation that the language has no public repository where anyone can put a module.

teatotal is that repository. A pull request adding a module is always accepted; whether a module is promoted on the front page is editorial, but the source goes in regardless, as long as no syntax error prevents it from being used in the simplest cases. If you wrote a module, PR yourself in. Anyone who fetched a module from here knows the one stable place its updates will keep arriving. We build the rules as it moves. Eventually there will be gating needed for security but let's not get ahead of ourselves now.

## The modules

The starting stock is in-house: modules grown inside our own desktop applications and cut out once their edges stopped moving. Each requires Tcl 9 and is MIT licensed; each `.tm` file is self-contained. Drop it on your `::tcl::tm::path` and `package require` it. Every module has a man page beside it.

| Module                      | The problem it solves                                                                                                                                                                 |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [deadman](deadman.md)       | An exec wedges, and the kill that follows takes the launcher while its forked children keep the lock file. deadman runs the command in its own process group, kills the whole tree on stall, wall clock, or the caller's own check, and reports the real exit code and which detector fired. |
| [leash](leash.md)           | Destroy a TclOO object and a timer it armed still fires, into a dead command name; the mixin's destructor cancels whatever is pending.                                                |
| [ocmdline](ocmdline.md)     | Parsing that keeps occurrence order, because a flag that negates the one after it or cuts a list in two needs the order a settings dict throws away. Parse and help both render from one option table, so the help cannot promise a flag the parser refuses, which is the drift every hand-rolled argv loop eventually grows. |
| [streamdoc](streamdoc.md)   | Stream a line into a Tk text widget while someone reads it, or fold a section above them, and their scroll jumps; streamdoc brackets every mutation so the line they are on stays put. |
| [streamtree](streamtree.md) | `ttk::treeview` cannot wrap a row, embed a widget in one, or take a streamed insert without the view jumping. This tree, drawn in a text widget under treeview's own vocabulary, can. |
| [tkdown](tkdown.md)         | Chat and transcript bodies arrive as markdown, which a text widget shows as raw markers; tkdown paints the forms such bodies carry (fences, tables, headings, lists, emphasis) onto plain tags, the parse half Tk-free. |

## Demos

Every module has a runnable demo under `demos/`, and one launcher shows them all:

```sh
wish9.0 demos/gallery.tcl
```

The gallery lists the demos, paints the selected module's man page into a reading pane, runs a demo as a deadman-watched subprocess with its output streaming below, and shows its source - and is itself built from the module stock it demonstrates. Each demo also runs standalone:

- `demos/deadman-demo.tcl` - a clean exit, a stall kill, and a TERM-trapper met with escalation; the same verdict dict for each.
- `demos/leash-demo.tcl` - counters whose timers die with their owner; destroy one card and the others keep counting.
- `demos/ocmdline-demo.tcl` - a tea timer whose help and parser render from one option table (`tclsh9.0 demos/ocmdline-demo.tcl --help`).
- `demos/streamdoc-demo.tcl` - a streaming feed of foldable regions that never moves the line you are reading.
- `demos/streamtree-demo.tcl` - a sortable, resizable, streaming tree drawn in one text widget.
- `demos/tkdown-demo.tcl` - a markdown sampler pane; the font-size spinbox refits the table live.

## Contributing

Send a pull request with your `name-version.tm` file and a `name.md` man page beside it. That is the whole bar: the PR will be merged.

The in-house modules grow inside the applications they were written for and sync here when a version is published. This repository is the published home of their source and man pages: the code evolves in its host, and each release lands here as the stable copy you fetch.

## License

[MIT](LICENSE).
