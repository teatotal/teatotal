# teatotal

teatotal comes from tea lovers' affection for Tcl and the lamentation that the language has no public repository where anyone can put a module.

teatotal is that repository. A pull request adding a module is always accepted; whether a module is promoted on the front page is editorial, but the source goes in regardless, as long as no syntax error prevents it from being used in the simplest cases. If you wrote a module, PR yourself in. Anyone who fetched a module from here knows the one stable place its updates will keep arriving. We build the rules as it moves. Eventually there will be gating needed for security but let's not get ahead of ourselves now.

## The modules

The starting stock is in-house: modules grown inside our own desktop applications and cut out once their edges stopped moving. Each requires Tcl 9 and is MIT licensed; each `.tm` file is self-contained. Drop it on your `::tcl::tm::path` and `package require` it. Every module has a man page beside it.

| Module                      | The problem it solves                                                                                                                                                                 |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [leash](leash.md)           | Destroy a TclOO object and a timer it armed still fires, into a dead command name; the mixin's destructor cancels whatever is pending.                                                |
| [ocmdline](ocmdline.md)     | This is the ordered veriation when order of the param matters. Parse and help both render from one option table, so the help cannot promise a flag the parser refuses, which is the drift every hand-rolled argv loop eventually grows.              |
| [streamdoc](streamdoc.md)   | Stream a line into a Tk text widget while someone reads it, or fold a section above them, and their scroll jumps; streamdoc brackets every mutation so the line they are on stays put. |
| [streamtree](streamtree.md) | `ttk::treeview` cannot wrap a row, embed a widget in one, or take a streamed insert without the view jumping. This tree, drawn in a text widget under treeview's own vocabulary, can. |
| [tkdown](tkdown.md)         | Chat and transcript bodies arrive as markdown, which a text widget shows as raw markers; tkdown paints the forms such bodies carry (fences, tables, headings, lists, emphasis) onto plain tags, the parse half Tk-free. |

## Contributing

Send a pull request with your `name-version.tm` file and a `name.md` man page beside it. That is the whole bar: the PR will be merged.

The in-house modules grow inside the applications they were written for and sync here when a version is published. This repository is the published home of their source and man pages: the code evolves in its host, and each release lands here as the stable copy you fetch.

## License

[MIT](LICENSE).
