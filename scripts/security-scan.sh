#!/usr/bin/env bash
# The security suite. Runs over a quarantined clone before anything is
# cherry-picked out of it.
#
#   security-scan.sh <quarantine-dir> [--quick]
#
# Writes report.md and report.json beside the clone and prints a verdict.
# Exit: 0 PASS, 10 REVIEW, 20 FAIL, 2 usage.
#
# Two rules govern this script. A check that could not run is reported as
# SKIPPED, never as a pass. And every finding is printed with its file and
# line, because a test fixture and an attack look identical to grep.
set -uo pipefail

dir=${1:?usage: security-scan.sh <quarantine-dir> [--quick]}
quick=${2:-}
[[ -d $dir ]] || { echo "error: not a directory: $dir" >&2; exit 2; }
dir=$(cd "$dir" && pwd)

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
patterns="${OSS_FIRST_PATTERNS:-$here/../config/deny-patterns.txt}"
out="$dir/.oss-first-report"; mkdir -p "$out"

slug=$(jq -r '.slug // "unknown"' "$dir/.oss-first-manifest.json" 2>/dev/null || echo unknown)
commit=$(jq -r '.commit // "unknown"' "$dir/.oss-first-manifest.json" 2>/dev/null || echo unknown)

# name|status|headline|detail-file
declare -a RESULTS=()
add() { RESULTS+=("$1|$2|$3|${4:-}"); }

have() { command -v "$1" >/dev/null 2>&1; }
TO=""; have timeout && TO=timeout; have gtimeout && TO=gtimeout
run() { local s=$1; shift; if [[ -n $TO ]]; then "$TO" "$s" "$@"; else "$@"; fi; }

printf '== security suite: %s @ %s ==\n\n' "$slug" "${commit:0:12}"

# ---------------------------------------------------------------- 1. secrets
if have gitleaks; then
  gitleaks detect --no-git --no-banner --redact \
    --report-format json --report-path "$out/gitleaks.json" \
    --source "$dir" >/dev/null 2>&1 || true
  n=$(jq 'length' "$out/gitleaks.json" 2>/dev/null || echo 0)
  if (( n > 0 )); then
    jq -r '.[] | "  \(.File):\(.StartLine)  \(.RuleID)"' "$out/gitleaks.json" 2>/dev/null \
      | sort -u | head -25 > "$out/gitleaks.txt"
    add secrets REVIEW "$n hard-coded secret(s) committed upstream" gitleaks.txt
  else
    add secrets PASS "no committed secrets"
  fi
else
  add secrets SKIPPED "gitleaks not installed"
fi

# ------------------------------------------------- 2. known vulnerabilities
if ! have osv-scanner; then
  add vulnerabilities SKIPPED "osv-scanner not installed"
elif [[ -z $(find "$dir" -maxdepth 5 -type f \( -name 'uv.lock' -o -name 'poetry.lock' -o -name 'requirements*.txt' -o -name 'Pipfile.lock' -o -name 'package-lock.json' -o -name 'pnpm-lock.yaml' -o -name 'yarn.lock' -o -name 'Cargo.lock' -o -name 'go.sum' -o -name 'go.mod' -o -name 'Gemfile.lock' -o -name 'composer.lock' -o -name 'pom.xml' -o -name 'gradle.lockfile' \) -not -path '*/.git/*' 2>/dev/null | head -1) ]]; then
  add vulnerabilities SKIPPED "no lockfile in the tree - osv-scanner reads lockfiles, not loose manifests, so the transitive set is unknown"
else
  run 300 osv-scanner scan source -r "$dir" --format json > "$out/osv.json" 2>/dev/null || true
  if jq -e . "$out/osv.json" >/dev/null 2>&1; then
    v=$(jq '[.results[]?.packages[]?.vulnerabilities[]?] | length' "$out/osv.json" 2>/dev/null || echo 0)
    worst=$(jq -r '[.results[]?.packages[]?.groups[]?.max_severity? // empty | tonumber?] | max // 0' \
            "$out/osv.json" 2>/dev/null || echo 0)
    if (( v > 0 )); then
      jq -r '.results[]?.packages[]? | . as $p | ($p.groups[]?.max_severity // "?") as $s |
             "  \($p.package.name // "?")@\($p.package.version // "?")  cvss=\($s)  \([$p.vulnerabilities[]?.id] | join(","))"' \
        "$out/osv.json" 2>/dev/null | sort -u | head -40 > "$out/osv.txt"
      if awk "BEGIN{exit !($worst >= 7.0)}"; then
        add vulnerabilities FAIL "$v known vuln(s), worst CVSS $worst" osv.txt
      else
        add vulnerabilities REVIEW "$v known vuln(s), worst CVSS $worst" osv.txt
      fi
    else
      add vulnerabilities PASS "no known vulnerabilities in the declared dependencies"
    fi
  else
    add vulnerabilities SKIPPED "osv-scanner emitted no parseable JSON (it may have timed out)"
  fi
fi

# -------------------------------------------------------- 3. semgrep rules
if [[ $quick == --quick ]]; then
  add static-analysis SKIPPED "--quick: semgrep not run"
elif have semgrep; then
  run 600 semgrep scan --config p/security-audit --config p/secrets \
    --metrics=off --quiet --no-git-ignore --json --timeout 20 \
    --output "$out/semgrep.json" "$dir" >/dev/null 2>&1 || true
  if jq -e .results "$out/semgrep.json" >/dev/null 2>&1; then
    e=$(jq '[.results[] | select(.extra.severity=="ERROR")] | length' "$out/semgrep.json")
    w=$(jq '[.results[] | select(.extra.severity=="WARNING")] | length' "$out/semgrep.json")
    jq -r '.results[] | "  \(.path | sub("^.*/";"")):\(.start.line)  [\(.extra.severity)] \(.check_id | sub("^.*\\.";""))"' \
      "$out/semgrep.json" 2>/dev/null | sort -u | head -40 > "$out/semgrep.txt"
    if (( e > 0 )); then add static-analysis REVIEW "$e error-level, $w warning-level finding(s)" semgrep.txt
    elif (( w > 0 )); then add static-analysis NOTE "$w warning-level finding(s)" semgrep.txt
    else add static-analysis PASS "no security findings"; fi
  else
    add static-analysis SKIPPED "semgrep produced no parseable output (offline? the rule registry needs network)"
  fi
else
  add static-analysis SKIPPED "semgrep not installed"
fi

# ------------------------------------------------- 4. hostile-code patterns
if [[ -f $patterns ]]; then
  : > "$out/patterns.txt"; hi=0; md=0; lo=0
  while IFS= read -r line; do
    [[ -z ${line:-} || $line == \#* ]] && continue
    # ::: delimited: the regexes contain | for alternation, so a single-char
    # IFS would tear them apart mid-pattern and silently match nothing.
    sev=${line%%:::*}; rest=${line#*:::}
    re=${rest%%:::*};  desc=${rest#*:::}
    [[ -z ${re:-} || $re == "$line" ]] && continue
    while IFS= read -r hit; do
      [[ -z $hit ]] && continue
      printf '  [%s] %s\n        %s\n' "$sev" "${hit#$dir/}" "$desc" >> "$out/patterns.txt"
      case $sev in high) hi=$((hi+1));; med) md=$((md+1));; *) lo=$((lo+1));; esac
    done < <(grep -rInE --binary-files=without-match "$re" "$dir" \
               --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.oss-first-report \
               --exclude='*.min.js' --exclude='*.map' 2>/dev/null \
             | cut -c1-200 | head -6)
  done < "$patterns"
  if (( hi > 0 )); then add hostile-patterns FAIL "$hi high, $md medium, $lo low" patterns.txt
  elif (( md > 0 )); then add hostile-patterns REVIEW "$md medium, $lo low" patterns.txt
  elif (( lo > 0 )); then add hostile-patterns NOTE "$lo low (telemetry / fingerprinting)" patterns.txt
  else add hostile-patterns PASS "no hostile patterns matched"; fi
else
  add hostile-patterns SKIPPED "pattern file not found at $patterns"
fi

# ---------------------------------------------------------- 5. licence gate
if [[ -x "$here/license-gate.sh" ]]; then
  "$here/license-gate.sh" "$dir" --json > "$out/license.json" 2>/dev/null
  lv=$(jq -r '.verdict // "review"' "$out/license.json" 2>/dev/null || echo review)
  cl=$(jq -r '.code_license // "?"' "$out/license.json" 2>/dev/null)
  wl=$(jq -r '.weight_verdict // "n/a"' "$out/license.json" 2>/dev/null)
  jq -r '(.notes // [])[] | "  - " + .' "$out/license.json" 2>/dev/null > "$out/license.txt"
  hl="code $cl"; [[ $wl != "n/a" ]] && hl="$hl; weights $wl"
  case $lv in
    deny)   add licence FAIL   "$hl" license.txt ;;
    review) add licence REVIEW "$hl" license.txt ;;
    *)      add licence PASS   "$hl" license.txt ;;
  esac
else
  add licence SKIPPED "license-gate.sh not found"
fi

# ------------------------------------------------------ 6. supply-chain shape
: > "$out/supply.txt"; sc=0
if [[ -f "$dir/package.json" ]]; then
  for k in preinstall postinstall prepare preuninstall; do
    if jq -e ".scripts.$k // empty" "$dir/package.json" >/dev/null 2>&1; then
      printf '  package.json runs a %s script: %s\n' "$k" \
        "$(jq -r ".scripts.$k" "$dir/package.json")" >> "$out/supply.txt"; sc=$((sc+1))
    fi
  done
fi
for m in "$dir/setup.py" "$dir/pyproject.toml"; do
  [[ -f $m ]] || continue
  grep -qE 'cmdclass|build_py|install_requires.*git\+' "$m" 2>/dev/null && {
    printf '  %s overrides a build/install command\n' "$(basename "$m")" >> "$out/supply.txt"; sc=$((sc+1)); }
done
while IFS= read -r f; do
  [[ -z $f ]] && continue
  printf '  non-default package registry in %s\n' "${f#$dir/}" >> "$out/supply.txt"; sc=$((sc+1))
done < <(grep -rlE '(--extra-index-url|--index-url|registry[[:space:]]*=[[:space:]]*https?://(?!registry\.npmjs))' \
         "$dir" --include='*.txt' --include='*.toml' --include='*.cfg' --include='.npmrc' \
         --exclude-dir=.git 2>/dev/null | head -5)
lock_missing=0
[[ -f "$dir/package.json" && ! -f "$dir/package-lock.json" && ! -f "$dir/pnpm-lock.yaml" && ! -f "$dir/yarn.lock" ]] && {
  printf '  package.json with no lockfile: the dependency set is not reproducible\n' >> "$out/supply.txt"; lock_missing=1; }
if (( sc > 0 )); then add supply-chain REVIEW "$sc lifecycle/registry signal(s)" supply.txt
elif (( lock_missing > 0 )); then add supply-chain NOTE "no lockfile" supply.txt
else add supply-chain PASS "no install-time hooks or off-index registries"; fi

# ------------------------------------------------------ 7. binaries, weights
: > "$out/binaries.txt"; bc=0
while IFS= read -r f; do
  [[ -z $f ]] && continue
  sz=$(wc -c < "$f" | tr -d ' ')
  printf '  %s\n        %s bytes  sha256 %s\n' "${f#$dir/}" "$sz" \
    "$(shasum -a 256 "$f" | awk '{print $1}')" >> "$out/binaries.txt"
  bc=$((bc+1))
done < <(find "$dir" -type f \( -name '*.ckpt' -o -name '*.pt' -o -name '*.pth' -o -name '*.th' \
  -o -name '*.onnx' -o -name '*.safetensors' -o -name '*.h5' -o -name '*.pb' -o -name '*.gguf' \
  -o -name '*.tflite' -o -name '*.dylib' -o -name '*.so' -o -name '*.dll' -o -name '*.a' \
  -o -name '*.wasm' -o -name '*.pkl' -o -name '*.npz' \) -not -path '*/.git/*' 2>/dev/null | head -60)
if (( bc > 0 )); then add binaries NOTE "$bc binary/weight file(s), each hashed for the ledger" binaries.txt
else add binaries PASS "no prebuilt binaries or weights in the tree"; fi

# ----------------------------------------------------------------- verdict
verdict=PASS
for r in "${RESULTS[@]}"; do
  s=$(cut -d'|' -f2 <<<"$r")
  [[ $s == FAIL ]] && { verdict=FAIL; break; }
  [[ $s == REVIEW ]] && verdict=REVIEW
done
skipped=$(printf '%s\n' "${RESULTS[@]}" | awk -F'|' '$2=="SKIPPED"' | wc -l | tr -d ' ')
if [[ $verdict == PASS && $skipped -gt 0 ]]; then
  verdict=REVIEW  # a suite with holes in it has not cleared anything
fi

# ------------------------------------------------------------ report.md
{
  printf '# Security report: %s\n\n' "$slug"
  printf -- '- Commit: `%s`\n- Scanned: %s\n- Quarantine: `%s`\n\n' \
    "$commit" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$dir"
  printf '## Verdict: %s\n\n' "$verdict"
  case $verdict in
    FAIL)   printf 'Do not adopt as-is. A failing check is named below.\n\n' ;;
    REVIEW) printf 'Adoptable only after a human reads the findings below and records the decision.\n\n' ;;
    PASS)   printf 'Every check ran and every check passed.\n\n' ;;
  esac
  (( skipped > 0 )) && printf '**%s check(s) could not run.** A skipped check is not a pass, which is why this cannot be PASS.\n\n' "$skipped"
  printf '| Check | Status | Detail |\n| --- | --- | --- |\n'
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r n s h _ <<<"$r"
    printf '| %s | **%s** | %s |\n' "$n" "$s" "$h"
  done
  printf '\n'
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r n s h f <<<"$r"
    [[ -z $f || ! -s "$out/$f" ]] && continue
    printf '### %s — %s\n\n```\n' "$n" "$s"
    head -45 "$out/$f"
    lines=$(wc -l < "$out/$f" | tr -d ' ')
    (( lines > 45 )) && printf '... %s more lines in .oss-first-report/%s\n' "$((lines-45))" "$f"
    printf '```\n\n'
  done
  printf '## What was not checked\n\n'
  printf 'Static analysis only. Nothing in this clone was executed, so runtime\n'
  printf 'behaviour is unverified. Run anything that must execute inside a\n'
  printf 'container with no network:\n\n'
  printf '```\ndocker run --rm --network none -v "%s":/src:ro -w /src <image> <cmd>\n```\n' "$dir"
} > "$out/report.md"

# ---------------------------------------------------------- report.json
{
  printf '{\n  "slug": "%s",\n  "commit": "%s",\n  "scanned_at": "%s",\n' \
    "$slug" "$commit" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "verdict": "%s",\n  "skipped_checks": %s,\n  "checks": [\n' "$verdict" "$skipped"
  for i in "${!RESULTS[@]}"; do
    IFS='|' read -r n s h f <<<"${RESULTS[$i]}"
    printf '    {"name": "%s", "status": "%s", "headline": "%s", "detail": "%s"}%s\n' \
      "$n" "$s" "$(printf '%s' "$h" | sed 's/"/\\"/g')" "$f" "$( ((i < ${#RESULTS[@]}-1)) && echo ',')"
  done
  printf '  ]\n}\n'
} > "$out/report.json"

for r in "${RESULTS[@]}"; do
  IFS='|' read -r n s h _ <<<"$r"
  printf '  %-18s %-8s %s\n' "$n" "$s" "$h"
done
printf '\nVERDICT: %s\n' "$verdict"
printf 'report: %s\n' "$out/report.md"

case $verdict in PASS) exit 0;; REVIEW) exit 10;; FAIL) exit 20;; esac
