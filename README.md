# teatotal

teatotal comes from tea lovers' affection for Tcl and the lamentation that the language has no public repository where anyone can put a module.

teatotal is that repository. A pull request adding a module is always accepted; whether a module is promoted on the front page is editorial, but the source goes in regardless, as long as no syntax error prevents it from being used in the simplest cases. If you wrote a module, PR yourself in. Anyone who fetched a module from here knows the one stable place its updates will keep arriving.

The gate is transparency, not review: a module here is plain Tcl source, one readable `.tm` file with no binary payload, so a PR is a diff anyone can inspect and what you fetch is what you can read. The one exception to always-accepted is malice; a module found to be malicious comes out. The rest of the rules we build as it moves.

There is nothing here to keep alive. No server, no client, no build farm, no registry format: a directory tree of `.tm` files is already a package repository, which is how TIP 189 designed them, and git carries the tree. Any clone is the complete archive, man pages included; the day this copy goes unmaintained, every clone already is the repository.

## The modules

The starting stock is in-house: modules grown inside our own desktop applications and cut out once their edges stopped moving. Every module here runs on Tcl 9. That is the house guarantee and the reason for the requirement: if your tclsh is 9.0, anything you fetch from this repository loads and works. For the in-house stock the label is tested, each suite running under tclsh9.0, or wish9.0 where Tk is involved, before a release lands here (see Tests). Each module is MIT licensed, self-contained in one `.tm` file, and has a man page beside it.

Drop a single module on your `::tcl::tm::path` and `package require` it, or take the shelf whole:

```sh
git clone https://github.com/teatotal/teatotal.git
```

```tcl
::tcl::tm::path add /path/to/teatotal
package require deadman
```

| Module                      | The problem it solves                                                                                                                                                                 |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [deadman](deadman.md)       | An exec wedges, and the kill that follows takes the launcher while its forked children keep the lock file. deadman runs the command in its own process group, kills the whole tree on stall, wall clock, or the caller's own check, and reports the real exit code and which detector fired. |
| [jobloop](jobloop.md)       | Background work on an event-driven app either blocks the loop or grows hand-rolled `after`/coroutine scaffolding with no cancel, no cap, and no account of what runs. jobloop runs each job as a coroutine on the loop you already have, with the full lifecycle: cancel mid-wait, per-kind caps, pacing floors and holds, an event stream. No `Thread` package anywhere; jobpool's event-loop twin. |
| [jobpool](jobpool.md)       | `tpool` runs your jobs but owns none of their lifecycle: you cannot cancel one that is already running, hold the queue, or cap one kind of work while the rest fan out. jobpool adds the per-job state machine, cooperative cancel and pause, per-kind caps, pacing floors and holds, and an event stream a subscriber follows; jobloop's threaded twin, built on the engine class jobloop publishes, for work that burns CPU or blocks. |
| [leash](leash.md)           | Destroy a TclOO object and a timer it armed still fires, into a dead command name; the mixin's destructor cancels whatever is pending.                                                |
| [ocmdline](ocmdline.md)     | Parsing that keeps occurrence order, because a flag that negates the one after it or cuts a list in two needs the order a settings dict throws away. Parse and help both render from one option table, so the help cannot promise a flag the parser refuses, which is the drift every hand-rolled argv loop eventually grows. |
| [streamdoc](streamdoc.md)   | Stream a line into a Tk text widget while someone reads it, or fold a section above them, and their scroll jumps; streamdoc brackets every mutation so the line they are on stays put. |
| [streamtree](streamtree.md) | `ttk::treeview` cannot wrap a row, embed a widget in one, or take a streamed insert without the view jumping. This tree, drawn in a text widget under treeview's own vocabulary, can. |
| [tkdown](tkdown.md)         | Chat and transcript bodies arrive as markdown, which a text widget shows as raw markers; tkdown paints the forms such bodies carry (fences, tables, headings, lists, emphasis) onto plain tags, the parse half Tk-free. |
| [yamlmuster](yamlmuster.md) | A hand-grown validator for parsed YAML makes every caller pay for every check, and its rules files are code you have to trust. yamlmuster indexes rules by level, group, and severity for partial validation - you pay only for the checks you select, and `stats` shows the bill - and loads them through a policed interpreter whose whole command table is `level`/`child`/`rule`, so a rules file can only declare. Dict-in: your parser parses, yamlmuster validates, at a measured YAML 1.1 (tcllib yaml) compatibility level. |

## Demos

Every module has a runnable demo under `demos/`, and one launcher shows them all:

```sh
wish9.0 demos/gallery.tcl
```

The gallery lists the demos, paints the selected module's man page into a reading pane, runs a demo as a deadman-watched subprocess with its output streaming below, and shows its source - and is itself built from the module stock it demonstrates. Each demo also runs standalone:

- `demos/deadman-demo.tcl` - a clean exit, a stall kill, and a TERM-trapper met with escalation; the same verdict dict for each.
- `demos/jobloop-demo.tcl` - two kinds of waiting work on one event loop, a paced kind launching in visible gaps, one job cancelled mid-wait between beats.
- `demos/jobpool-demo.tcl` - a batch through a two-slot pool, every state change printed, one job cancelled mid-run, one kind held to a single worker.
- `demos/leash-demo.tcl` - counters whose timers die with their owner; destroy one card and the others keep counting.
- `demos/ocmdline-demo.tcl` - a tea timer whose help and parser render from one option table (`tclsh9.0 demos/ocmdline-demo.tcl --help`).
- `demos/streamdoc-demo.tcl` - a streaming feed of foldable regions that never moves the line you are reading.
- `demos/streamtree-demo.tcl` - a sortable, resizable, streaming tree drawn in one text widget.
- `demos/tkdown-demo.tcl` - a markdown sampler pane; the font-size spinbox refits the table live.
- `demos/yamlmuster-demo.tcl` - a campaign ruleset over clean and broken dicts, two partial passes with the bill each one paid, a hostile rules file refused at load (`tclsh9.0 demos/yamlmuster-demo.tcl`).

## Tests

Every module carries a standalone test under `tests/`, and one script runs them together:

```sh
tests/run.sh
```

The runner turns the StreamTree and StreamDoc audit gates on for the whole suite, so a passing assertion is not the whole bar: a test that silently desyncs an engine mark still fails on the `INVARIANT @` line the gate writes. Tk tests run under `wish9.0` on a private Xvfb display, never an existing one where the windows would land over your work; the rest run under `tclsh9.0`. The script prints one line per test, exits with the failure count, and ends on `SUITE PASS` or `SUITE FAILED`. The `bench-*.tcl` scripts beside them are benchmarks, left out of the run.

## Contributing

Send a pull request with your `name-version.tm` file (lowercase name, as TIP 590 recommends) and a `name.md` man page beside it. The module is plain Tcl source and runs on Tcl 9: that is the promise every download from here carries, so yours carries it too. That is the whole bar: the PR will be merged.

The in-house modules grow inside the applications they were written for and sync here when a version is published. This repository is the published home of their source and man pages: the code evolves in its host, and each release lands here as the stable copy you fetch.

## License

[MIT](LICENSE).
