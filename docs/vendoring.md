# Releases and vendored copies

A module here is one file, named `name-version.tm`. An application that uses one copies it into its own `vendor/` directory rather than reaching for this repository at runtime.

## The rule

A version number names one exact content. `yamlmuster-2.1.tm` is the same file everywhere it appears: here, in every application carrying it, and in every clone of both.

Two things follow.

A vendored file is not edited. Edit one in place to test something if you like, but that edit does not get committed. When the code has to change, it changes at its home here, and the vendored copy is replaced whole.

A release is not amended. Once `2.1` exists, `2.1` is finished. A correction of any size is `2.2`.

## Why this is worth the ceremony

The failure it prevents leaves no trace. Two files sharing a version number and differing in content break no test and show up in no diff anyone is reading. `package require` loads whichever one it finds and reports nothing wrong. The application keeps working, and its vendored copy quietly describes behaviour the module no longer has.

Comments are the usual casualty. Drifted code gets caught by a test. A drifted header comment gets read and believed.

## Work that is not finished yet

Development still has to be committed and tested while it is in progress, and the release name is not available for it. Give the draft a name of its own, beside the release:

    modules/yamlmuster/yamlmuster-2.0.tm      the release
    modules/yamlmuster/yamlmuster-2.1a1.tm    the draft

Tcl resolves stable versions ahead of unstable ones, so `package require yamlmuster` keeps loading 2.0 and does not see the draft. A test that wants the draft asks for it:

    package require -exact yamlmuster 2.1a1

`package prefer latest` earlier in the same interpreter has the same effect for every subsequent require.

## Finishing

Finalising is one commit rather than a sequence:

- the draft becomes the release at its home, `2.1a1` renamed to `2.1`
- that file replaces the vendored copy, `2.0` deleted and `2.1` added
- the draft is deleted

Do the three together. Split across commits, the tree spends the gap holding a vendored copy that matches no release anywhere.

## Vendoring from the other side

An application holding vendored copies is the other half of this, and the rule belongs in its own repository as well as here. One line in whatever file that repository keeps its rules in, naming the directory it governs and pointing here for the procedure. Give it its own line rather than a clause inside a paragraph about something else, or it gets read as background and skipped.
