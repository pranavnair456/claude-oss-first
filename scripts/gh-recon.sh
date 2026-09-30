#!/usr/bin/env bash
# Stage 1: judge a repo without cloning it.
#
#   gh-recon.sh <owner/repo> [owner/repo ...]        score named repos
#   gh-recon.sh --search "<query>" [--limit N] [--language L]
#   ... [--json]
#
# Every call is a read. Nothing is written to disk, nothing is cloned. The
# GitHub API will hand over a repo's README, licence and manifests as file
# contents, which is enough to decide whether a clone is even warranted.
set -uo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
command -v gh >/dev/null || die "gh not installed"
command -v jq >/dev/null || die "jq not installed"

repos=() query="" limit=10 language="" as_json=0
while (($#)); do
  case $1 in
    --search)   query=${2:?}; shift 2 ;;
    --limit)    limit=${2:?}; shift 2 ;;
    --language) language=${2:?}; shift 2 ;;
    --json)     as_json=1; shift ;;
    -*)         die "unknown flag: $1" ;;
    *)          repos+=("$1"); shift ;;
  esac
done

if [[ -n $query ]]; then
  # Permissive licences first, and nothing abandoned. Ranking free and
  # maintained above merely popular is the whole point of the stage.
  mapfile -t found < <(gh search repos "$query" --limit "$limit" \
      ${language:+--language "$language"} \
      --json fullName --jq '.[].fullName' 2>/dev/null)
  repos+=("${found[@]:-}")
fi
((${#repos[@]})) || die "nothing to score: pass owner/repo or --search"

now=$(date -u +%s)
scorecards=()

for slug in "${repos[@]}"; do
  [[ -z $slug ]] && continue
  meta=$(gh api "repos/$slug" 2>/dev/null) || { printf 'skip %s (not readable)\n' "$slug" >&2; continue; }

  name=$(jq -r '.full_name' <<<"$meta")
  desc=$(jq -r '.description // ""' <<<"$meta")
  stars=$(jq -r '.stargazers_count // 0' <<<"$meta")
  forks=$(jq -r '.forks_count // 0' <<<"$meta")
  issues=$(jq -r '.open_issues_count // 0' <<<"$meta")
  spdx=$(jq -r '.license.spdx_id // "NONE"' <<<"$meta")
  archived=$(jq -r '.archived' <<<"$meta")
  is_fork=$(jq -r '.fork' <<<"$meta")
  parent=$(jq -r '.parent.full_name // ""' <<<"$meta")
  pushed=$(jq -r '.pushed_at // ""' <<<"$meta")
  created=$(jq -r '.created_at // ""' <<<"$meta")
  kb=$(jq -r '.size // 0' <<<"$meta")
  topics=$(jq -r '(.topics // []) | join(", ")' <<<"$meta")
  homepage=$(jq -r '.homepage // ""' <<<"$meta")

  # days since the last push
  if [[ -n $pushed ]]; then
    ps=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$pushed" +%s 2>/dev/null || echo "$now")
    age=$(( (now - ps) / 86400 ))
  else age=9999; fi

  # gh api writes its error body to stdout on a 404, so each call is captured
  # and only parsed when it actually succeeded. Otherwise a repo with no
  # releases reports an error object as its version.
  api_json() { gh api "$1" 2>/dev/null; }

  # bus factor: how many people have actually touched it
  if j=$(api_json "repos/$slug/contributors?per_page=100&anon=false"); then
    contrib=$(jq 'if type=="array" then length else 0 end' <<<"$j" 2>/dev/null || echo 0)
  else contrib=0; fi

  # release cadence
  if j=$(api_json "repos/$slug/releases/latest"); then
    rel=$(jq -r 'if type=="object" and has("tag_name") then .tag_name else "" end' <<<"$j" 2>/dev/null || echo "")
  else rel=""; fi

  # is it actually maintained, or just pushed by a bot
  since=$(date -u -v-90d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '90 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo 1970-01-01T00:00:00Z)
  if j=$(api_json "repos/$slug/commits?since=$since&per_page=100"); then
    commits_90=$(jq 'if type=="array" then length else 0 end' <<<"$j" 2>/dev/null || echo 0)
  else commits_90=0; fi

  # what it declares it needs: read the manifest without cloning
  deps="?"
  for m in package.json pyproject.toml requirements.txt Cargo.toml go.mod; do
    body=$(gh api "repos/$slug/contents/$m" --jq '.content' 2>/dev/null | tr -d '\n' | base64 -d 2>/dev/null) || continue
    [[ -z $body ]] && continue
    case $m in
      package.json)   deps=$(jq -r '((.dependencies // {}) | length)' <<<"$body" 2>/dev/null || echo "?")"  (package.json)" ;;
      pyproject.toml) deps=$(grep -cE '^[[:space:]]*"[A-Za-z0-9_.-]+' <<<"$body" 2>/dev/null || echo "?")"  (pyproject.toml)" ;;
      requirements.txt) deps=$(grep -cvE '^[[:space:]]*(#|$)' <<<"$body" 2>/dev/null || echo "?")"  (requirements.txt)" ;;
      *) deps="declared in $m" ;;
    esac
    break
  done

  # licence class from the policy
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  lic_lower=$(printf '%s' "$spdx" | tr '[:upper:]' '[:lower:]')
  policy="${OSS_FIRST_POLICY:-$here/../config/license-policy.yml}"
  lic_class="review"
  if [[ -f $policy ]]; then
    in_list() { awk -v k="$1" '$0 ~ "^"k":" {i=1;next} i && /^[a-z_]+:/ {i=0} i && /-/ {gsub(/^[[:space:]]*-[[:space:]]*|[[:space:]]*#.*$|"/,"");print tolower($0)}' "$policy"; }
    grep -qx -- "$lic_lower" <(in_list deny)   && lic_class="deny"
    [[ $lic_class == review ]] && grep -qx -- "$lic_lower" <(in_list allow) && lic_class="allow"
  fi
  [[ $spdx == NONE || $spdx == "NOASSERTION" ]] && { lic_class="deny"; spdx="NONE"; }

  # --- the score ---------------------------------------------------------
  # Maintained and permissive beats popular. A repo nobody can fix is a
  # liability whatever its star count.
  score=0 flags=()
  (( age <= 30 ))  && score=$((score+25)) || { (( age <= 120 )) && score=$((score+18)); }
  (( age > 365 ))  && flags+=("no push in $((age/365))+ year(s)")
  (( age > 120 && age <= 365 )) && flags+=("last push $age days ago")
  case $lic_class in
    allow)  score=$((score+25)) ;;
    review) score=$((score+8));  flags+=("licence $spdx needs a recorded decision") ;;
    deny)   flags+=("licence $spdx is a blocker, not a caveat") ;;
  esac
  (( contrib >= 10 )) && score=$((score+20)) || { (( contrib >= 3 )) && score=$((score+12)) || flags+=("bus factor $contrib"); }
  (( stars >= 1000 )) && score=$((score+15)) || { (( stars >= 100 )) && score=$((score+10)) || { (( stars >= 20 )) && score=$((score+5)); }; }
  (( commits_90 >= 10 )) && score=$((score+15)) || { (( commits_90 >= 1 )) && score=$((score+8)) || flags+=("no commits in 90 days"); }
  [[ -n $rel ]] && score=$((score+5)) || flags+=("no tagged release")
  [[ $archived == true ]] && { score=$((score-40)); flags+=("ARCHIVED - read-only upstream"); }
  [[ $is_fork == true ]] && { score=$((score-15)); flags+=("fork of $parent - prefer the upstream unless the fork is the maintained one"); }
  (( score < 0 )) && score=0

  if   (( score >= 75 )) && [[ $lic_class == allow ]]; then rec="ADOPT"
  elif (( score >= 45 )) && [[ $lic_class != deny  ]]; then rec="VET"
  elif [[ $lic_class == deny ]];                          then rec="REJECT"
  else rec="WEAK"; fi

  if ((${#flags[@]})); then
    flags_json=$(printf '%s\n' "${flags[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
  else
    flags_json='[]'
  fi

  scorecards+=("$(jq -nc \
    --arg n "$name" --arg d "$desc" --arg l "$spdx" --arg lc "$lic_class" \
    --arg r "$rec" --arg t "$topics" --arg rel "$rel" --arg dep "$deps" --arg hp "$homepage" \
    --argjson s "$score" --argjson st "$stars" --argjson fk "$forks" --argjson is "$issues" \
    --argjson ag "$age" --argjson c "$contrib" --argjson c90 "$commits_90" --argjson kb "$kb" \
    --arg arc "$archived" --arg fork "$is_fork" --arg par "$parent" \
    --argjson fl "$flags_json" \
    '{repo:$n,description:$d,recommendation:$r,score:$s,license:$l,license_class:$lc,
      stars:$st,forks:$fk,open_issues:$is,days_since_push:$ag,contributors:$c,
      commits_90d:$c90,latest_release:$rel,size_kb:$kb,declared_deps:$dep,
      topics:$t,homepage:$hp,archived:($arc=="true"),fork:($fork=="true"),parent:$par,flags:$fl}')")
done

all=$(printf '%s\n' "${scorecards[@]}" | jq -sc 'sort_by(-.score)')

if (( as_json )); then printf '%s\n' "$all" | jq .; exit 0; fi

printf '\n== recon: %s candidate(s), no clone ==\n\n' "$(jq 'length' <<<"$all")"
printf '%-42s %6s %5s %-14s %-8s %s\n' REPO SCORE CALL LICENCE PUSHED FLAGS
printf '%s\n' "$(printf '%.0s-' {1..110})"
jq -r '.[] | [.repo, .score, .recommendation, .license, (.days_since_push|tostring + "d"),
             (if (.flags|length)>0 then (.flags|join("; ")) else "-" end)] | @tsv' <<<"$all" \
  | awk -F'\t' '{printf "%-42s %6s %5s %-14s %-8s %s\n", $1,$2,$3,$4,$5,$6}'

printf '\n'
jq -r '.[] | "### \(.repo)  [\(.recommendation)]\n\(.description)\n" +
  "  licence \(.license) (\(.license_class)) | \(.stars) stars | \(.contributors) contributors | " +
  "\(.commits_90d) commits/90d | \(.size_kb) KiB | deps \(.declared_deps)\n" +
  (if .latest_release != "" then "  latest release \(.latest_release)\n" else "" end) +
  (if .topics != "" then "  topics: \(.topics)\n" else "" end) +
  (if (.flags|length)>0 then "  flags: \(.flags|join(" | "))\n" else "" end)' <<<"$all"

printf 'ADOPT = clear; VET = sandbox-clone.sh then security-scan.sh; REJECT = licence blocks it.\n'
printf 'Nothing above was cloned. Read the code with:\n'
printf '  gh api repos/<slug>/contents/<path> --jq .content | base64 -d\n'
