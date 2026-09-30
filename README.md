# oss-first

A Claude Code plugin for using GitHub as a build resource instead of writing
everything yourself — and for not getting burned doing it.

Three rules sit above everything else here:

1. **Do not waste time building what someone else has already built**, probably
   better than you would have.
2. **Free over paid.** A paid option only gets named after the free ones have
   been tried and found wanting, with the reason stated.
3. **Look to the community first** for a solution.

The problem with acting on those rules is that pulling in someone else's code
is how projects acquire malware, licence obligations they cannot meet, and
dependencies nobody can maintain. So the rules come with a pipeline.

## The four stages

| Stage | Command | What it does | What it refuses to do |
|---|---|---|---|
| 1. Scout | `/oss-scout` | Searches and scores candidates through the GitHub API; returns a build-vs-adopt call | Clone anything, or write to disk |
| 2+3. Vet | `/oss-vet` | Hardened clone into quarantine, then a seven-check security suite | Build, install or execute a single line |
| 4. Adopt | `/oss-adopt` | Wires it in, verifies end to end, records provenance | Claim it works without running the gate |
| Standing | `/oss-radar` | Deterministic daily sweep for what is new, maintained and free | Recommend anything it has not vetted |

`/oss <what you need>` runs all four in order.

## Install

```
/plugin marketplace add pranavnair456/claude-oss-first
/plugin install oss-first
```

Then, once:

```bash
~/.claude/plugins/.../scripts/preflight.sh --install
```

which installs the four scanners via Homebrew. Every tool in this pipeline is
free and open source — that is rule 2 applied to itself:

| Tool | License | Job |
|---|---|---|
| [gitleaks](https://github.com/gitleaks/gitleaks) | MIT | committed secrets |
| [osv-scanner](https://github.com/google/osv-scanner) | Apache-2.0 | known CVEs, from OSV.dev |
| [semgrep](https://github.com/semgrep/semgrep) | LGPL-2.1 | static analysis |
| [trufflehog](https://github.com/trufflesecurity/trufflehog) | AGPL-3.0 | verified secret detection |
| `gh` + `jq` + `git` | — | everything else |

Nothing here needs an API key, a subscription, or a token to *research* public
repositories. A token is only needed to create and maintain your own.

## Stage 1 is read-only, on purpose

`git clone` is not a read operation — it runs hooks, and a repo you are merely
curious about should not get to execute anything. The GitHub API will hand over
a repo's README, licence, file tree and manifests as content:

```bash
gh api repos/<owner>/<repo>/contents/README.md --jq .content | base64 -d
gh api repos/<owner>/<repo>/git/trees/HEAD?recursive=1 --jq '.tree[].path'
```

That is enough to decide whether a clone is warranted at all.
`scripts/gh-recon.sh` scores candidates on last push, licence class,
contributor count, commits in 90 days, releases and archived/fork status, and
returns `ADOPT` / `VET` / `WEAK` / `REJECT`.

## The quarantine is enforced, not promised

Clones land in `~/.claude/oss-sandbox/<owner>__<repo>__<sha>/`, deliberately
nowhere near a project tree. `sandbox-clone.sh` refuses to clone anywhere else.
The clone is hardened:

- `core.hooksPath=/dev/null` at clone time, and `.git/hooks` deleted afterwards
- no submodules, no LFS payloads, no symlinks, `protocol.file.allow=never`
- depth 1, single branch, no tags
- **the execute bit stripped from every file**
- `.git` made read-only

And a `PreToolUse` hook denies `pip install`, `npm install`, `uv sync`, `make`,
`chmod +x`, running upstream scripts, `docker build`, and `git submodule` for
any command touching quarantine — while leaving reading, grepping, hashing and
scanning alone, because that is the entire job. If something genuinely must
execute:

```bash
docker run --rm --network none -v <quarantine>:/src:ro -w /src <image> <cmd>
```

## A skipped check is not a pass

The suite degrades rather than failing, and reports every check it could not
run as `SKIPPED`. **A run with any skipped check cannot return PASS** — it
returns REVIEW. This is the single most important behaviour in the tool: a
security report that silently omits a check is worse than no report, because it
gets believed.

The seven checks: secrets, known CVEs, semgrep, a hostile-pattern corpus
(install-time RCE, credential theft, exfiltration endpoints, anti-forensics,
miners, obfuscation, typosquatting), the licence gate, supply-chain shape
(lifecycle hooks, off-index registries, missing lockfile), and a hash inventory
of every binary and weight file.

## Licence is a blocker, not a caveat

`config/license-policy.yml` grades licences `allow` / `review` / `deny`, and
**grades code and model weights separately**. That separation is the point: a
model repo is routinely MIT in its code and silent about its checkpoints, and
the checkpoints are what you ship. A permissive code licence does not grant
rights to the weights.

The cases that recur:

- **AGPL** reaches a hosted service, not just a shipped binary.
- **CC-BY-NC** weights: the code being MIT is irrelevant.
- **No licence file** is all-rights-reserved, not permission.
- **LGPL** is fine dynamically linked, a problem statically linked.
- **GPL** run on your own server is use, not distribution.

## Provenance, so adoption is auditable

`/oss-adopt` appends a row to the project's existing ledger: upstream URL,
pinned commit, sha256 and byte count for binaries, licence, commercial verdict,
vet date, and **what it replaced**. Templates in `templates/`.

`scripts/collect-licenses.py --against LEDGER.md` then reads the project's
lockfiles, asks PyPI and npm what each resolved package is licensed under, and
names the ones whose licence is not `allow` and which the ledger does not
mention. It does not dump every package at you; it names the open questions.

## The radar

`scripts/radar.py` sweeps `gh search` against `config/interests.yml` and writes
a digest. It is deterministic — no model in the loop — so it costs nothing to
run daily and gives the same answer twice. `.github/workflows/radar.yml` runs
it on a schedule and files the digest as a GitHub issue, using the runner's own
`gh` and the automatic `GITHUB_TOKEN`: no API key, no secret, and it runs with
your laptop shut. Repos already reported are held in `radar/seen.txt`, so a
quiet digest means nothing new happened.

## Layout

```
skills/       the four stage skills Claude follows
commands/     /oss, /oss-scout, /oss-vet, /oss-adopt, /oss-radar
scripts/      the deterministic parts: recon, clone, scan, gate, collect, radar
hooks/        the PreToolUse quarantine guard
config/       licence policy, hostile-pattern corpus, radar interests
templates/    ledger, artifact notice, adoption record
reference/    the long-form playbook
```

Every script runs standalone with `--help`-shaped usage on the first line, so
none of this depends on being driven by a model.

## License

MIT. The scanners it invokes keep their own licences, listed above.
