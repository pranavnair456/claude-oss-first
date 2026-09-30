---
name: oss-vet
description: Use before adopting, cloning, vendoring, copying code from, or installing any third-party repository or package - and whenever the user asks whether some repo or dependency is safe, or says "check this repo", "is this package safe", "vet this", "audit this dependency". Clones into a hardened quarantine outside every project tree, runs a free security suite (secrets, CVEs, semgrep, hostile patterns, licence, supply-chain), and returns PASS/REVIEW/FAIL. Nothing is executed.
---

# OSS vet

Stages 2 and 3 of four: get the code somewhere it cannot do harm, then find out
what is in it. Nothing leaves this stage without a verdict.

## Stage 2 — quarantine

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-clone.sh <owner/repo> [ref]
```

Prints the quarantine path. It lands in `~/.claude/oss-sandbox/<owner>__<repo>__<sha>/`,
which is deliberately nowhere near a project. The clone is hardened: hooks
disabled at clone time *and* deleted afterwards, no submodules, no LFS
payloads, no symlinks, `protocol.file.allow=never`, depth 1, and the execute
bit stripped from every file.

Two rules, both enforced rather than trusted:

- **Never clone into a project tree.** The script refuses to.
- **Never build, install or run anything in quarantine.** A `PreToolUse` hook
  denies `pip install`, `npm install`, `make`, `chmod +x`, running upstream
  scripts, and the rest. If you find yourself wanting to, that is the signal to
  stop, not to work around it.

If something genuinely must execute to be evaluated, a container with no
network and a read-only mount is the only sanctioned route:

```bash
docker run --rm --network none -v <quarantine-dir>:/src:ro -w /src <image> <cmd>
```

## Stage 3 — the suite

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/security-scan.sh <quarantine-dir>
# add --quick to skip semgrep when you need a fast first read
```

Seven checks, every tool free and open source:

| Check | Tool | Catches |
|---|---|---|
| secrets | gitleaks | credentials committed upstream |
| vulnerabilities | osv-scanner | known CVEs in the resolved dependency set |
| static analysis | semgrep | injection, unsafe deserialisation, weak crypto |
| hostile patterns | grep corpus | install-time RCE, credential theft, exfil, anti-forensics, miners, obfuscation |
| licence | license-gate.sh | commercial-use blockers, **code vs weights graded separately** |
| supply chain | manifest read | lifecycle hooks, off-index registries, missing lockfile |
| binaries | shasum | every prebuilt binary and weight file, hashed for the ledger |

Writes `report.md` and `report.json` into `.oss-first-report/` beside the
clone. Exit code: 0 PASS, 10 REVIEW, 20 FAIL.

### A skipped check is not a pass

The suite degrades rather than failing, and reports every check it could not
run as `SKIPPED`. A run with any skipped check cannot return PASS — it returns
REVIEW. If a scanner is missing, install it and re-run:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh --install
```

Never report a repo as clean on the strength of a suite with holes in it.

## Reading the verdict

- **PASS** — every check ran and passed. Proceed to `oss-adopt`.
- **REVIEW** — a human decision is required. Read the findings, then say which
  are real and which are noise, *with your reasoning*. A test fixture and an
  attack look identical to grep; that is exactly why every hit is reported with
  its file and line. Do not launder a REVIEW into a PASS by dismissing findings
  in bulk.
- **FAIL** — do not adopt as-is. Name the failing check. Options are: a
  different library, a pinned older version without the CVE, or upstreaming a
  fix. "Ignore it" is not among them.

## Licence is a blocker, not a caveat

`deny` means the component does not enter the tree, whatever its technical
merit. The recurring cases:

- **AGPL** reaches a hosted service, not just a shipped binary.
- **CC-BY-NC** on model weights: the code being MIT is irrelevant.
- **No licence file at all** is all-rights-reserved, not permission.
- **Permissive code, unstated weights** — grade the weights on their own; the
  stricter verdict governs.
- **GPL/LGPL** are a recorded decision, not an automatic no: running a GPL tool
  on your own server is use, not distribution, and invoking it as a separate
  executable over a pipe is not linking. State which situation you are in.

## Report

Verdict first, then the findings that drove it, then a one-line
recommendation. Cite the report path so the evidence is checkable. Leave the
quarantine in place until adoption is finished — the adopt stage needs the
hashes.
