#!/usr/bin/env bash
# Clone a repo into quarantine. Nothing here is trusted and nothing here is
# executable.
#
#   sandbox-clone.sh <owner/repo | url> [ref]
#
# Prints the quarantine path on stdout. Everything else goes to stderr so the
# path can be captured directly.
set -euo pipefail

say() { printf '%s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ $# -ge 1 ]] || die "usage: sandbox-clone.sh <owner/repo | url> [ref]"
target=$1; ref=${2:-}

# --- resolve to owner/repo and an https url -------------------------------
if [[ $target =~ ^(https?://|git@) ]]; then
  slug=$(printf '%s' "$target" | sed -E 's#^(https?://[^/]+/|git@[^:]+:)##; s#\.git$##')
else
  slug=$target
fi
[[ $slug =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "not an owner/repo: $slug"
owner=${slug%%/*}; repo=${slug##*/}
url="https://github.com/${slug}.git"

# --- the quarantine root, asserted ----------------------------------------
# A clone must never land in a project tree. This is the whole point, so it is
# checked rather than assumed.
root="${OSS_SANDBOX:-$HOME/.claude/oss-sandbox}"
case "$root" in
  "$HOME/.claude/oss-sandbox"*) : ;;
  *) die "OSS_SANDBOX must live under ~/.claude/oss-sandbox (got: $root)" ;;
esac
mkdir -p "$root"
if git -C "$root" rev-parse --show-toplevel >/dev/null 2>&1; then
  die "quarantine root is inside a git repository; refusing to clone into a project tree"
fi

# --- name the directory after the exact commit ----------------------------
sha=""
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  if [[ -n $ref ]]; then
    sha=$(gh api "repos/${slug}/commits/${ref}" --jq .sha 2>/dev/null || true)
  else
    br=$(gh api "repos/${slug}" --jq .default_branch 2>/dev/null || true)
    [[ -n ${br:-} ]] && sha=$(gh api "repos/${slug}/commits/${br}" --jq .sha 2>/dev/null || true)
  fi
fi
[[ -z $sha ]] && sha=$(git ls-remote "$url" "${ref:-HEAD}" 2>/dev/null | awk 'NR==1{print $1}' || true)
[[ -z $sha ]] && die "cannot resolve a commit for ${slug}${ref:+@$ref}"
short=${sha:0:12}

dest="$root/${owner}__${repo}__${short}"
if [[ -d $dest ]]; then
  say "already in quarantine at the same commit: $dest"
  printf '%s\n' "$dest"; exit 0
fi

# --- the hardened clone ---------------------------------------------------
# No credential prompts, no LFS payloads, no hooks, no submodules, no local
# protocol, shallow and single-branch. Hooks are the reason `git clone` is not
# a read-only operation, so they are disabled twice: once by config and once
# by deletion.
say "cloning ${slug}@${short} into quarantine (no hooks, no submodules, depth 1)"
tmp="${dest}.partial.$$"
rm -rf "$tmp"
GIT_TERMINAL_PROMPT=0 \
GIT_ASKPASS=/usr/bin/true \
GIT_CONFIG_GLOBAL=/dev/null \
GIT_LFS_SKIP_SMUDGE=1 \
git -c core.hooksPath=/dev/null \
    -c protocol.file.allow=never \
    -c core.symlinks=false \
    -c advice.detachedHead=false \
    clone --quiet --depth 1 --single-branch --no-tags \
          --recurse-submodules=no --shallow-submodules \
          ${ref:+--branch "$ref"} "$url" "$tmp" \
  || { rm -rf "$tmp"; die "clone failed"; }

got=$(git -C "$tmp" rev-parse HEAD)
if [[ -n $ref && $got != "$sha" ]]; then
  say "warning: resolved $short but cloned ${got:0:12} (ref moved mid-clone)"
fi

rm -rf "$tmp/.git/hooks"
# Nothing in quarantine is executable. Static analysis does not need the bit,
# and removing it means a stray ./configure cannot run even by accident.
find "$tmp" -type f -not -path '*/.git/*' -exec chmod a-x {} + 2>/dev/null || true
chmod -R a-w "$tmp/.git" 2>/dev/null || true

mv "$tmp" "$dest"

files=$(find "$dest" -type f -not -path '*/.git/*' | wc -l | tr -d ' ')
bytes=$(du -sk "$dest" | awk '{print $1*1024}')
cat > "$dest/.oss-first-manifest.json" <<JSON
{
  "slug": "${slug}",
  "url": "https://github.com/${slug}",
  "ref": "${ref:-<default branch>}",
  "commit": "${got}",
  "cloned_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "file_count": ${files},
  "size_bytes": ${bytes},
  "hardening": [
    "core.hooksPath=/dev/null at clone time",
    ".git/hooks removed after clone",
    "protocol.file.allow=never",
    "core.symlinks=false",
    "submodules not initialised",
    "git-lfs smudge skipped",
    "execute bit stripped from every file",
    ".git made read-only"
  ],
  "trust": "none - unreviewed third-party code"
}
JSON
chmod a-x "$dest/.oss-first-manifest.json"

say "quarantined: ${files} files, $((bytes/1024)) KiB"
say "next: security-scan.sh \"$dest\""
printf '%s\n' "$dest"
