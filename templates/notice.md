# <Component> <artifact or weights>

<!--
Provenance for one vendored artifact, kept beside the artifact itself. Modelled
on the basic_pitch NOTICE.md pattern, which is the standard to hit: a reader who
opens this file can verify every claim in it at the primary source.

The point of the byte count and sha256 is that "the same file" becomes a
checkable statement rather than a hope.
-->

`<filename>` is <one sentence on what the artifact is>, copied unchanged from
<upstream URL> at tag `<tag>` (`<exact upstream path>`, <N> bytes,
sha256 `<hash>`).

Copyright <year> <holder>. Licensed under <licence>; the licence text is in
`LICENSE` beside this file and the row in `/<ledger>.md` records the adoption.

<!-- If the weights carry different terms from the code, say both here and say
     which governs. If upstream is silent on the weights, say that plainly. -->

Ported code, with attribution in the module docstrings:

- `<path/in/this/repo.py>`: `<function>`, `<function>` (`<upstream/file.py>`).
  <Any deliberate deviation from upstream, and why.>

<!-- The deviations matter more than the list of names. Someone comparing this
     to upstream needs to know which differences are intentional. -->

Citation: <authors>, "<title>", <venue> <year>.
