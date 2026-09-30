# Adopting <upstream(s)>

<!--
The decision record for a substantial adoption. Modelled on the
stem-tools-adoption spec: repos read in full, licences checked at primary
sources, and an explicit list of what was deliberately left out.

The "Not adopted" section is the part future readers need most. Without it, the
next person re-evaluates everything you already rejected.
-->

<date>. Analysis of <what> and the decisions taken from it. <Say how deeply it
was read, and that licences were checked at primary sources rather than from
badges.> Nothing was copied yet; this document names what will be copied, where
it lands, and what stays out.

- `<owner/repo>` `<version>`: <licence>. <One or two lines: what it is, its
  shape, rough size, test coverage.>

## Verdict

<The call, in the first sentence. "No restart" / "adopt the X, not the Y" /
"build it ourselves because …". Then the reasoning.>

## Security

Quarantine: `<path>` at commit `<sha>`. Suite verdict: <PASS/REVIEW/FAIL>.
<Findings that mattered and why they were accepted or not. If any check was
skipped, say which — a skipped check is not a pass.>

## Licence

| Component | License | Commercial | Notes |
| --- | --- | --- | --- |
| <code> | <id> | Yes/No | <the reasoning where use-vs-distribution or linking decides it> |
| <weights> | <id> | Yes/No | <graded separately from the code, always> |

## Reuse catalogue

<What is being taken, grouped by where it lands. Name the upstream file for
each item so attribution can be written into the module docstring.>

### <area or milestone>

- `<upstream/file>` -> `<our/file>`: <what it does, and what hand-written code
  it replaces or deletes.>

## Deviations from upstream

<Every intentional difference, with the reason. This is what makes a later diff
against upstream readable.>

## Not adopted

<The explicit no-list, with a reason each. Licence, quality, unnecessary
coupling, solves-the-adjacent-problem, or simply not needed. Include anything
that looked attractive and was rejected — that is the expensive knowledge.>

## Known softness

<What this leaves unresolved, and what would settle it.>
