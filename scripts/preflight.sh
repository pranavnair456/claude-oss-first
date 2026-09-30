#!/usr/bin/env bash
# Verify the toolchain the other scripts depend on, and install what is
# missing. Idempotent: safe to run at the start of any session.
#
# Every tool here is free and open source. That is a rule, not a coincidence.
set -uo pipefail

REQUIRED_CORE=(git gh jq)
SCANNERS=(gitleaks osv-scanner semgrep trufflehog)
OPTIONAL=(docker)

missing_core=() missing_scanners=()
for t in "${REQUIRED_CORE[@]}"; do command -v "$t" >/dev/null || missing_core+=("$t"); done
for t in "${SCANNERS[@]}";      do command -v "$t" >/dev/null || missing_scanners+=("$t"); done

printf '== oss-first preflight ==\n\n'

if ((${#missing_core[@]})); then
  printf 'MISSING (required): %s\n' "${missing_core[*]}"
  printf 'Install with: brew install %s\n' "${missing_core[*]}"
  exit 1
fi
printf 'core          ok   (%s)\n' "$(printf '%s ' "${REQUIRED_CORE[@]}")"

if ((${#missing_scanners[@]})); then
  printf 'scanners      MISSING: %s\n' "${missing_scanners[*]}"
  if [[ "${1:-}" == "--install" ]] && command -v brew >/dev/null; then
    printf '\ninstalling with brew...\n'
    brew install "${missing_scanners[@]}" || exit 1
    printf 'done\n'
  else
    printf 'Install with: brew install %s\n' "${missing_scanners[*]}"
    printf '(or re-run: preflight.sh --install)\n'
    printf '\nThe suite still runs without them, but every absent check is\n'
    printf 'reported as SKIPPED. A skipped check is not a pass.\n'
  fi
else
  printf 'scanners      ok   (%s)\n' "$(printf '%s ' "${SCANNERS[@]}")"
fi

for t in "${OPTIONAL[@]}"; do
  if command -v "$t" >/dev/null; then printf '%-13s ok   (dynamic checks available)\n' "$t"
  else printf '%-13s absent (dynamic checks unavailable; static only)\n' "$t"; fi
done

printf '\n'
if gh auth status >/dev/null 2>&1; then
  acct=$(gh api user --jq .login 2>/dev/null || echo '?')
  printf 'gh auth       ok   (%s)\n' "$acct"
  printf 'gh scopes     %s\n' "$(gh auth status 2>&1 | sed -n 's/.*Token scopes: //p' | head -1)"
else
  printf 'gh auth       NOT LOGGED IN\n'
  printf '  Reading and researching public repos needs no token, but scoring\n'
  printf '  and the radar use the API and will rate-limit hard without one.\n'
  printf '  Run: gh auth login\n'
fi

sandbox="${OSS_SANDBOX:-$HOME/.claude/oss-sandbox}"
printf 'quarantine    %s\n' "$sandbox"
[[ -d "$sandbox" ]] && printf '              %s clone(s) currently held\n' \
  "$(find "$sandbox" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
