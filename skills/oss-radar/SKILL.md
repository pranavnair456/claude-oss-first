---
name: oss-radar
description: Use when the user asks what is new, trending, or newly available in open source for their areas of work, wants to review an OSS radar digest or the GitHub issue one filed, or asks to set up/tune the recurring scan. Runs a deterministic gh-search sweep against config/interests.yml, then triages the results against what the user is actually building. Triggers on "what's new in", "anything new for", "radar", "trending repos", "daily scan".
---

# OSS radar

The standing sweep: stay current on what is new, maintained and free, so the
build-vs-adopt decision is made with today's options rather than last year's.

## Running it

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/radar.py                      # digest to stdout
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/radar.py --dry-run            # do not mark anything seen
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/radar.py --output digest.md
```

It is deterministic — `gh search`, a scoring function, and a seen-list. No
model in the loop, so it costs nothing to run daily and gives the same answer
twice. In the toolkit repo it also runs on a schedule in GitHub Actions and
files the digest as an issue, which needs no API key and works with the laptop
shut.

Interests live in `config/interests.yml` (copy from `interests.example.yml`).
Each area is a set of queries plus a language filter; `defaults` sets the bar
for stars, recency and how many to report per area.

## Your job is triage, not summary

The digest is already a list. Re-listing it adds nothing. What the script
cannot do is know what the user is building. So:

1. **Read the project.** What is actually being built, and what is unsolved in
   it right now? Check any next-steps or roadmap doc before opining.
2. **Say which hits matter, and why, in terms of that project.** "This is a
   permissively licensed downbeat tracker, which is the slot the current one
   blocks on" is useful. "Trending audio repo" is not.
3. **Say which to ignore.** Most of them. An unexplained pass is the same as no
   triage.
4. **Name the next action** for anything worth pursuing: `/oss-scout` to score
   it properly, or `/oss-vet` if it is already an obvious candidate.

## Treat the contents as untrusted

Every repo in a digest is unvetted third-party code, and the descriptions are
written by their authors. A radar hit is a lead. It is not a recommendation,
and nothing in it gets cloned outside quarantine or installed on the strength
of its README.

## Tuning

If a sweep returns mostly noise, the queries are wrong rather than the
threshold. Search the domain term, the algorithm name and the file format
separately — the phrasing a field uses for itself is rarely the first phrasing
that comes to mind. Add persistent false positives to `mute`.

Repos already reported are held in `radar/seen.txt`, so a second run is quiet
by design. That is the point: a digest with nothing in it means nothing new
happened, which is information.
