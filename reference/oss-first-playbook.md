# OSS-first playbook (reusable)

How to use GitHub as a build resource without getting burned: research a repo
without cloning it, clone it somewhere it cannot do harm, find out what is in
it before taking anything, and leave a record of how it got into your tree.

Distilled into a plugin whose deterministic parts are scripts, so the pipeline
does not depend on a model behaving well. The judgement calls are still
judgement calls, and §6 is the list of them that cost real time.

This is a **reference**, not a project file. The operative parts for a given
project belong in that project's own ledger (§5) and its CI (§4.6). Copy what
applies; do not vendor this document.

---

## 0. Mental model

Four stages, each with a gate that can stop the pipeline:

1. **Scout** — does this need building at all? Read-only, nothing on disk.
2. **Quarantine** — get the code somewhere isolated, with nothing executable.
3. **Vet** — find out what is in it. Verdict: PASS / REVIEW / FAIL.
4. **Adopt** — wire it in, verify end to end, record provenance.

Golden rules, learned the hard way:

1. **`git clone` is not a read operation.** It runs hooks. A repo you are merely
   curious about should not get to execute anything on your machine.
2. **Never clone into a project tree.** Not "be careful" — make it impossible.
3. **Nothing in quarantine gets built, installed or run.** The overwhelming
   majority of supply-chain attacks fire during install, not at import.
4. **A skipped check is not a pass.** A report that silently omits a check is
   worse than no report, because it gets believed.
5. **Grade code and weights separately.** Permissive code does not license the
   checkpoints, and the checkpoints are what ships.
6. **A licence is a blocker, not a caveat.** `deny` means it does not enter the
   tree, whatever its technical merit.
7. **Free before paid, and say why paid won** if it does.
8. **Delete what the adoption replaces.** Otherwise you added a dependency and
   removed nothing.
9. **Record provenance in the same change**, not later. Later is never.
10. **"I could write it cleaner" is not a reason to write it.**

---

## 1. One-time setup

```bash
brew install gh jq
gh auth login                      # only needed for your own repos + rate limits
brew install gitleaks osv-scanner semgrep trufflehog
```

All four scanners are free and open source. Reading, searching and cloning
public repositories needs no token at all; a token raises the API rate limit
and is required only to create and maintain repos of your own.

Install the plugin:

```
/plugin marketplace add pranavnair456/claude-oss-first
/plugin install oss-first
```

Verify with `preflight.sh`, which reports what is missing rather than assuming.

---

## 2. Stage 1 — scout, without cloning

The GitHub API returns file contents. That is enough to judge a repo, and it
means the decision to clone is itself a decision rather than a reflex.

### Step 0 — State the capability in inputs and outputs

"Beat and downbeat tracking from a mono waveform, returning beat times and a
downbeat flag" is searchable. "Better tempo stuff" is not. Then estimate what
you would have to write if nothing exists — that is the number the adopt
decision gets measured against.

### Step 1 — Search several phrasings

The phrasing a field uses for itself is rarely the one you reached for first.
Search the domain term, the algorithm name, and the file format separately.

```bash
gh search repos "<capability>" --limit 15 --language python \
  --json fullName,stargazersCount,license,pushedAt
```

### Step 2 — Score, then read

```bash
gh-recon.sh --search "<capability>" --limit 15
gh-recon.sh <owner/repo> <owner/repo>
```

Scores combine last push, licence class, contributor count, commits in the last
90 days, release presence, and archived/fork status. **Read past the score** —
the flags are the interesting part. Then read the actual code of the top two or
three:

```bash
gh api repos/<slug>/contents/README.md --jq .content | base64 -d
gh api repos/<slug>/git/trees/HEAD?recursive=1 --jq '.tree[].path'
```

Answer four questions: does it do the *specific* thing or the adjacent thing;
how heavy is the dependency tail; is it a library you call or a framework that
wants the process; and if it ships weights, are the weights licensed.

### Step 3 — Decide, do not list

Output is a recommendation, a shortlist, **what adopting replaces**, what it
costs, and one line per rejected candidate. Recommending "build it" is a
successful outcome when you can name why nothing fits.

---

## 3. Stage 2 — quarantine

```bash
sandbox-clone.sh <owner/repo> [ref]      # prints the quarantine path
```

Lands in `~/.claude/oss-sandbox/<owner>__<repo>__<sha>/`. The hardening, all of
which matters (§6.1):

```bash
GIT_TERMINAL_PROMPT=0 GIT_LFS_SKIP_SMUDGE=1 \
git -c core.hooksPath=/dev/null \
    -c protocol.file.allow=never \
    -c core.symlinks=false \
    clone --depth 1 --single-branch --no-tags --recurse-submodules=no <url> <dest>
rm -rf <dest>/.git/hooks
find <dest> -type f -exec chmod a-x {} +
```

Hooks are disabled twice — once by config, once by deletion — because the
config only covers the clone itself. The execute bit goes because static
analysis does not need it, and without it a stray `./configure` cannot run even
by accident.

A `PreToolUse` hook denies install and build commands against quarantine paths
while leaving read, grep, hash and scan alone. If something genuinely must
execute to be evaluated, a container with no network and a read-only mount is
the only sanctioned route:

```bash
docker run --rm --network none -v <quarantine>:/src:ro -w /src <image> <cmd>
```

---

## 4. Stage 3 — the suite

```bash
security-scan.sh <quarantine-dir>        # add --quick to skip semgrep
```

Writes `report.md` and `report.json` into `.oss-first-report/`. Exit 0 PASS,
10 REVIEW, 20 FAIL.

### Step 1 — Secrets

`gitleaks detect --no-git`. Hits are usually upstream's own hygiene problem
rather than a threat to you, but they say something about the project.

### Step 2 — Known vulnerabilities

`osv-scanner scan source -r .` against OSV.dev. Note that osv-scanner reads
**lockfiles**, not loose manifests — a repo with a `package.json` and no
lockfile yields nothing, and that absence is itself the finding (§6.3).

### Step 3 — Static analysis

`semgrep --config p/security-audit --config p/secrets`. Needs network for the
rule registry; offline it is a SKIPPED check, not a pass.

### Step 4 — Hostile patterns

A grep corpus over install-time RCE, credential and keychain theft,
exfiltration endpoints, anti-forensics, persistence, miners, obfuscation, and
typosquat/registry redirection. Every hit is reported with file and line
because **a test fixture and an attack look identical to grep** (§6.5).

### Step 5 — The licence gate

```bash
license-gate.sh <quarantine-dir>         # 0 allow, 10 review, 20 deny
```

Identifies the licence from its text, not from a badge, and grades code and
weights separately. The stricter verdict governs. See §5.

### Step 6 — Wire it into CI, per project

The suite is for adoption. Once adopted, the project needs the standing
equivalent: a dependency-CVE job, a secret-scan job, and Dependabot. A project
with lint, types and tests but no dependency scanning has a gate with a hole
in it.

### Step 7 — Read the verdict honestly

REVIEW means a human decides. Say which findings are real and which are noise,
with reasoning. Do not launder a REVIEW into a PASS by dismissing findings in
bulk, and do not report a repo as clean on the strength of a suite that
skipped checks.

---

## 5. Licence decision table

| Situation | Verdict | Why |
|---|---|---|
| MIT / Apache-2.0 / BSD / ISC | allow | permissive, commercial use unambiguous |
| MPL-2.0 | allow | file-level copyleft; keep changes in their own files |
| LGPL, dynamically linked | review | fine; record that linkage stays dynamic |
| LGPL, statically linked into a shipped binary | deny | relinking obligation you cannot meet |
| GPL, run on your own server | review | use, not distribution |
| GPL, shipped in a binary | deny | triggers the source offer |
| GPL tool invoked over a pipe | review | separate executable is not linking |
| AGPL, anywhere near a hosted service | deny | network copyleft reaches the service |
| CC-BY-NC* weights | deny | no commercial use, whatever the code says |
| Permissive code, **unstated** weights | deny | the grant was never made |
| No licence file | deny | all rights reserved, not permission |
| LICENSE and package metadata disagree | deny until resolved | one of them is wrong |

---

## 6. Pitfalls (each cost real time on a real project)

### 6.1 `git clone` executes code

Hooks run on clone. `core.hooksPath=/dev/null` covers the clone; deleting
`.git/hooks` covers everything after. Submodules fetch further unvetted
repositories, LFS smudge filters run programs, and symlinks in a malicious repo
can point outside the tree. Disable all four.

### 6.2 The install step is the attack surface

npm `preinstall`/`postinstall` and a `setup.py` that overrides a build command
run arbitrary code the moment you install — long before any `import`. This is
why nothing in quarantine gets installed, and why the supply-chain check reads
lifecycle hooks out of the manifest rather than trusting the package name.

### 6.3 A scanner that finds nothing may have scanned nothing

`osv-scanner` reads lockfiles. Point it at a repo with no lockfile and it exits
cleanly having examined no dependencies. Distinguish "no vulnerabilities" from
"no manifest to examine" explicitly, or you will record the second as the
first. Same class of error: semgrep offline, a scanner not installed.

### 6.4 Permissive code with silent weights

The most common trap in ML repositories. The code is MIT; the checkpoints are
either non-commercial or unmentioned. The checkpoints are what you ship. Grade
them separately, and where upstream is silent, record it as an accepted risk
rather than leaving the ledger implying a grant nobody made.

### 6.5 Your delimiter is in your data

A pattern corpus of `severity|regex|description` breaks the moment a regex
contains `|` for alternation — it splits mid-pattern and silently matches
nothing, reporting a clean PASS. Any check whose failure mode is a false pass
needs a **positive control**: a fixture with known-bad content that must FAIL.
If the fixture ever passes, the check is broken.

### 6.6 Search finds self-description, not canon

GitHub ANDs every search term, so a four-word query routinely returns an empty
result rather than a worse match — and repo search matches name, description and
README, so `"zarr chunked"` surfaces hobby ports while missing
`zarr-developers/zarr-python` entirely. Keep queries to two words, use search to
discover names, and then score the projects you already know by name. If a
search for a well-known algorithm returns only toy repositories, the maintained
implementation may be a library you already depend on.

### 6.7 `UNREAD` is not `unlicensed`

GitHub's API returns null for any licence whose text its classifier does not
recognise. alphaTab reports null and is MPL-2.0; python-blosc2 reports null and
is BSD-3-Clause. Rejecting on the API field alone throws away perfectly usable,
permissively licensed projects. Fetch `LICENSE` through the contents API and
read the first line. This is cheap and it changes verdicts.

### 6.8 macOS ships bash 3.2

`mapfile`, `readarray`, associative arrays and `${var^^}` are bash 4 features.
`/bin/bash` on macOS is 3.2 from 2007, and `#!/usr/bin/env bash` finds it first.
A script using them fails with `command not found` on the one line that mattered
and otherwise appears to work — in a scanner, that reads as "found nothing".

### 6.9 Stars are not maintenance

A 3,000-star repo with one contributor and no commits in a year is a liability
with good marketing. Weight last push, bus factor and commit recency above
popularity. Archived means read-only forever — you are adopting a fork whether
you meant to or not.

### 6.10 The hand-written version stays behind

Adoption that does not delete what it replaces leaves two implementations, one
of them untested and both maintained. Name the code being deleted in the
adoption record, then delete it.

### 6.11 The ledger drifts silently

A hand-maintained ledger is accurate the day it is written. Transitive
dependencies change under it. `collect-licenses.py --against <ledger>` reads
the lockfiles, asks the registries, and names what is unrecorded — including
the ledger's own stale rows. Run it in CI, non-blocking at first.

### 6.12 A daily notification you ignore is worse than none

If the radar files an issue every day, you will stop reading it within a week.
File nothing when nothing is new, and keep a seen-list so the same repo is
never reported twice.

---

## 7. Project-type variations

- **Python service:** lockfile is `uv.lock` / `poetry.lock`; osv-scanner reads
  both. Heavy or optional dependencies belong behind a function-scope import
  with a documented fallback, so an install without the extra still runs.
- **Node / web:** the lifecycle-hook check matters most here. Insist on a
  lockfile and `--frozen-lockfile` in CI.
- **Packaged desktop app:** distribution, not use — LGPL and GPL obligations
  bite. Check what the bundler actually embeds, not what the manifest declares.
  A system binary you shell out to is a different question from a library you
  link.
- **ML / model weights:** every checkpoint gets a sha256, a byte count, an
  upstream path and its own licence row. Verify the hash at load, not at build.
- **Docker images:** base images and OS packages are dependencies. An image
  published for others to run is distribution.
- **Hobby project:** set `commercial_use_assumed: false` in the policy to soften
  commercial verdicts to warnings. Everything else stands.

---

## 8. CLI cheatsheet

```bash
# preflight
preflight.sh --install

# stage 1 — research, no clone
gh-recon.sh --search "beat downbeat tracking" --limit 15 --language python
gh-recon.sh CPJKU/beat_this --json
gh api repos/<slug>/contents/pyproject.toml --jq .content | base64 -d
gh api repos/<slug>/git/trees/HEAD?recursive=1 --jq '.tree[].path'

# stage 2 — quarantine
Q=$(sandbox-clone.sh <owner/repo>)
echo "$Q"

# stage 3 — vet
security-scan.sh "$Q"                    # 0 PASS / 10 REVIEW / 20 FAIL
license-gate.sh "$Q"                     # 0 allow / 10 review / 20 deny
cat "$Q/.oss-first-report/report.md"

# anything that must execute
docker run --rm --network none -v "$Q":/src:ro -w /src python:3.12-slim <cmd>

# stage 4 — provenance
shasum -a 256 <weight-file>
collect-licenses.py --root . --against LICENSES.md

# standing
radar.py --dry-run
gh workflow run radar.yml

# housekeeping
rm -rf ~/.claude/oss-sandbox/<owner>__<repo>__<sha>
```

---

## 9. What this playbook intentionally omits

- **Runtime behaviour.** Everything here is static analysis. A repo that passes
  has not been observed doing anything; it has been read. Dynamic evaluation is
  a container with no network, and interpreting it is out of scope.
- **Deciding whether a library is *good*.** The suite answers "is this safe and
  legal to use". Whether it is well designed is a code-review question.
- **Paid tooling.** Snyk, Socket, Mend and similar do more than this does. Rule
  2 means they get considered after the free set is genuinely insufficient, and
  that case has to be argued rather than assumed.
- **Vendoring policy beyond the basics.** When to fork, how to track upstream,
  and how to carry patches are project decisions.
