---
name: oss-scout
description: Use before building any non-trivial capability from scratch, and whenever the user asks whether something already exists, wants a library or tool recommendation, or says "find me a repo/package for X". Researches GitHub read-only via the gh CLI, scores candidates on licence, maintenance and bus factor, and returns an explicit build-vs-adopt call. Never clones anything. Triggers on "is there a library for", "what should I use for", "don't build it if it exists", "find an open source", "scout".
---

# OSS scout

Stage 1 of four. The question you are answering is not "what exists?" but
**"should we write this at all?"** Assume the answer is no until the search says
otherwise.

Three rules govern every recommendation:

1. **Do not rebuild what exists.** Someone has probably solved this and had
   more iterations at it than you will get.
2. **Free over paid.** A paid option is only surfaced once the free ones have
   been named and found wanting, and you say *why* they fall short.
3. **Community first.** Look outward before proposing new code.

## The hard constraint: nothing gets cloned

This stage is read-only. Not "mostly read-only" — you do not run `git clone`,
you do not write to disk, you do not install anything. The GitHub API will hand
over a repo's README, licence and manifests as file contents, which is enough
to decide whether a clone is even warranted. Cloning happens in `oss-vet`,
after a decision, and only into quarantine.

```bash
gh api repos/<owner>/<repo>/contents/README.md --jq .content | base64 -d
gh api repos/<owner>/<repo>/contents/pyproject.toml --jq .content | base64 -d
gh api repos/<owner>/<repo>/git/trees/HEAD?recursive=1 --jq '.tree[].path'
```

## Process

### Step 1 — State what the capability actually is

One sentence, in terms of inputs and outputs, before searching. "Beat and
downbeat tracking from a mono waveform, returning beat times and a downbeat
flag" is searchable. "Better tempo stuff" is not.

Then say what you would have to write if nothing exists, and roughly how much.
This is the number the adopt decision is measured against.

### Step 2 — Search wide, then score

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/gh-recon.sh --search "<capability>" --limit 15 --language python
${CLAUDE_PLUGIN_ROOT}/scripts/gh-recon.sh <owner/repo> <owner/repo> ...
```

Run several differently-worded searches. The phrasing a field uses for itself is
rarely the phrasing you reached for first: search the domain term, the algorithm
name, and the file format.

`gh-recon.sh` scores on last push, licence class, contributor count, commits in
the last 90 days, release presence, and archived/fork status, and emits
`ADOPT` / `VET` / `WEAK` / `REJECT`. Read past the score — the flags are the
interesting part.

### Step 3 — Read the code of the top two or three

Scores rank; they do not decide. For each finalist, read enough to answer:

- Does it do the specific thing, or the adjacent thing? Adjacent is worse than
  nothing, because it looks like a fit until integration.
- How heavy is the dependency tail? A package that drags in torch to do
  arithmetic is not free.
- Is the interface one you can call, or a CLI/framework wanting to own the
  process?
- **If it ships model weights, are the weights licensed?** Permissive code with
  silent checkpoints is the single most common trap in ML repos. The code
  licence does not grant rights to the weights, and the weights are what ships.
- Is there a test suite? Its absence tells you what maintenance will feel like.

### Step 4 — Deliver a decision, not a list

Report, in this order:

1. **Recommendation** — adopt X, or build it, in one line.
2. **The shortlist** — table of candidates with licence, maintenance, verdict.
3. **What adopting replaces** — the specific code you will not now write, or
   the existing code this deletes. This is the rule made concrete.
4. **What it costs** — new dependencies, licence obligations, the weights
   question, and the maintenance risk if the bus factor is low.
5. **Why not the others** — one line each. If a paid option is named, say what
   the free ones could not do.

Recommend building only when you can name the reason no existing project fits:
licence blocks it, it is unmaintained, or it solves the adjacent problem. "I
could write it cleaner" is not a reason.

## Then stop

Scout ends with a decision. If the decision is to adopt, hand off to
`oss-vet` — do not clone here, and do not start wiring anything in.

## Red flags in your own reasoning

| Thought | Reality |
|---|---|
| "I'll just write a quick version" | That is the rule this stage exists to break. Search first. |
| "Let me clone it to look" | The API reads files. Cloning is stage 2 and needs quarantine. |
| "2k stars, looks fine" | Stars measure attention, not maintenance. Check the last push and the bus factor. |
| "It's MIT, we're clear" | If it ships weights, grade those separately. |
| "Close enough" | Adjacent-fit libraries cost more than writing it. Say so. |
