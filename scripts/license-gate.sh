#!/usr/bin/env bash
# Classify a quarantined repo's licence as allow / review / deny, grading code
# and model weights separately.
#
#   license-gate.sh <quarantine-dir> [--json]
#
# Exit: 0 allow, 10 review, 20 deny. Written so CI can branch on it.
set -uo pipefail

dir=${1:?usage: license-gate.sh <quarantine-dir> [--json]}
mode=${2:-}
[[ -d $dir ]] || { echo "error: not a directory: $dir" >&2; exit 2; }

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
policy="${OSS_FIRST_POLICY:-$here/../config/license-policy.yml}"

# Read a list under a top-level key of the policy yaml without needing yq.
policy_list() {
  [[ -f $policy ]] || return 0
  awk -v key="$1" '
    $0 ~ "^"key":" {inside=1; next}
    inside && /^[a-z_]+:/ {inside=0}
    inside && /^[[:space:]]*-[[:space:]]*/ {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      sub(/[[:space:]]*#.*$/, "", line)
      gsub(/^"|"$/, "", line)
      if (line != "") print tolower(line)
    }' "$policy"
}
ALLOW=$(policy_list allow); REVIEW=$(policy_list review); DENY=$(policy_list deny)
SUSPECT=$(policy_list suspect_phrases)

# --- find the licence text ------------------------------------------------
lic_file=""
for c in LICENSE LICENSE.txt LICENSE.md LICENCE LICENCE.txt COPYING COPYING.txt \
         LICENSE-MIT LICENSE-APACHE license LICENSE.rst; do
  [[ -f "$dir/$c" ]] && { lic_file="$dir/$c"; break; }
done
if [[ -z $lic_file ]]; then
  lic_file=$(find "$dir" -maxdepth 2 -iname 'licen[sc]e*' -o -maxdepth 2 -iname 'copying*' 2>/dev/null \
             | grep -v '/\.git/' | head -1)
fi

# --- identify the SPDX id from the text -----------------------------------
identify() {
  local f=$1 t
  [[ -f $f ]] || { echo "unknown"; return; }
  t=$(tr '[:upper:]' '[:lower:]' < "$f" | tr -s '[:space:]' ' ')
  case "$t" in
    *"gnu affero general public license"*)              echo "agpl-3.0-only" ;;
    *"gnu lesser general public license"*"version 3"*)  echo "lgpl-3.0-only" ;;
    *"gnu lesser general public license"*"version 2.1"*) echo "lgpl-2.1-only" ;;
    *"gnu lesser general public license"*)              echo "lgpl-2.1-only" ;;
    *"gnu general public license"*"version 3"*)         echo "gpl-3.0-only" ;;
    *"gnu general public license"*"version 2"*)         echo "gpl-2.0-only" ;;
    *"gnu general public license"*)                     echo "gpl-3.0-only" ;;
    *"apache license"*"version 2.0"*)                   echo "apache-2.0" ;;
    *"mozilla public license"*"2.0"*)                   echo "mpl-2.0" ;;
    *"attribution-noncommercial-sharealike"*)           echo "cc-by-nc-sa-4.0" ;;
    *"attribution-noncommercial"*)                      echo "cc-by-nc-4.0" ;;
    *"attribution-sharealike"*)                         echo "cc-by-sa-4.0" ;;
    *"creative commons"*"noncommercial"*)               echo "cc-by-nc-4.0" ;;
    *"cc0"*|*"public domain dedication"*)               echo "cc0-1.0" ;;
    *"server side public license"*)                     echo "sspl-1.0" ;;
    *"business source license"*)                        echo "busl-1.1" ;;
    *"elastic license"*)                                echo "elastic-2.0" ;;
    *"permission is hereby granted, free of charge"*"substantial portions"*) echo "mit" ;;
    *"redistribution and use in source and binary"*"neither the name"*)      echo "bsd-3-clause" ;;
    *"redistribution and use in source and binary"*)    echo "bsd-2-clause" ;;
    *"permission to use, copy, modify, and/or distribute"*) echo "isc" ;;
    *"this is free and unencumbered software"*)          echo "unlicense" ;;
    *"boost software license"*)                          echo "bsl-1.0" ;;
    *"zlib"*"altered source versions"*)                  echo "zlib" ;;
    *"python software foundation"*)                      echo "psf-2.0" ;;
    *) echo "unknown" ;;
  esac
}

verdict_for() {
  local id=$1
  grep -qx -- "$id" <<<"$DENY"   && { echo deny;   return; }
  grep -qx -- "$id" <<<"$REVIEW" && { echo review; return; }
  grep -qx -- "$id" <<<"$ALLOW"  && { echo allow;  return; }
  echo review
}

code_id=$(identify "$lic_file")
code_verdict=$(verdict_for "$code_id")
notes=()
[[ -z $lic_file ]] && { code_id="none"; code_verdict="deny"; notes+=("no licence file found: absence of a licence is all-rights-reserved, not permission"); }
[[ $code_id == unknown && -n $lic_file ]] && notes+=("licence text present but not recognised: read $(basename "$lic_file") by hand")

# --- the trap: permissive code, silent weights ---------------------------
# A model repo is routinely MIT in its code and says nothing at all about its
# checkpoints. The weights are the thing you actually ship, so they are graded
# on their own and the stricter verdict governs.
weights=$(find "$dir" -type f \( -name '*.ckpt' -o -name '*.pt' -o -name '*.pth' -o -name '*.th' \
  -o -name '*.onnx' -o -name '*.safetensors' -o -name '*.h5' -o -name '*.pb' -o -name '*.bin' \
  -o -name '*.gguf' -o -name '*.tflite' -o -name '*.pkl' -o -name '*.npz' -o -name '*.joblib' \) -not -path '*/.git/*' 2>/dev/null | head -50)
weight_count=$(printf '%s' "$weights" | grep -c . || true)
weight_verdict="n/a"; weight_id="n/a"

if (( weight_count > 0 )); then
  wl=$(find "$dir" -maxdepth 3 -type f \( -iname '*weight*licen[sc]e*' -o -iname '*model*licen[sc]e*' \
       -o -iname 'LICENSE.weights' -o -iname 'NOTICE*' \) -not -path '*/.git/*' 2>/dev/null | head -1)
  if [[ -n $wl ]]; then
    weight_id=$(identify "$wl"); weight_verdict=$(verdict_for "$weight_id")
    notes+=("weights carry their own licence file: $(basename "$wl") -> $weight_id")
  else
    doc_hit=$(grep -rilE 'weights? (are|is) (released|licens|distribut)|checkpoints? (are|is) (released|licens)' \
              "$dir" --include='*.md' --include='*.rst' --include='*.txt' 2>/dev/null | head -1)
    if [[ -n $doc_hit ]]; then
      weight_id="stated-in-prose"; weight_verdict="review"
      notes+=("weights discussed only in prose ($(basename "$doc_hit")): confirm the grant at the primary source")
    else
      weight_id="unstated"; weight_verdict="deny"
      if [[ $code_verdict == allow ]]; then
        notes+=("$weight_count weight file(s) present and NO separate weights licence: a permissive code licence does not grant rights to the checkpoints, which are the part you ship")
      else
        notes+=("$weight_count weight file(s) present and NO separate weights licence, so the repo licence ($code_id) governs them too")
      fi
    fi
  fi
fi

# --- phrases that override an otherwise clean id -------------------------
susp=()
while IFS= read -r p; do
  [[ -z $p ]] && continue
  hit=$(grep -rilF "$p" "$dir" --include='*.md' --include='*.txt' --include='*.rst' \
        --include='LICENSE*' --include='*.toml' --include='*.cfg' 2>/dev/null | grep -v '/\.git/' | head -1)
  [[ -n $hit ]] && susp+=("\"$p\" in $(basename "$hit")")
done <<<"$SUSPECT"

if ((${#susp[@]})) && [[ $code_verdict == allow ]]; then
  code_verdict="review"
  notes+=("an allowed licence id but restrictive wording elsewhere: ${susp[0]}")
fi

# --- declared metadata vs the licence file ------------------------------
declared=""
for m in "$dir/package.json" "$dir/pyproject.toml" "$dir/setup.cfg" "$dir/Cargo.toml"; do
  [[ -f $m ]] || continue
  d=$(grep -ioE '"?licen[sc]e"?[[:space:]]*[:=][[:space:]]*"?\{?[^",}]+' "$m" 2>/dev/null \
      | head -1 | sed -E 's/.*[:=][[:space:]]*"?\{?//' | tr -d '"' | tr '[:upper:]' '[:lower:]' \
      | sed 's/[[:space:]]*$//')
  [[ -n ${d:-} ]] && { declared="$d ($(basename "$m"))"; break; }
done
if [[ -n $declared && $code_id != unknown ]]; then
  base=${declared%% *}
  if [[ -n $base && $base != *"$code_id"* && $code_id != *"${base%%-*}"* ]]; then
    notes+=("metadata says '$declared' but the licence file reads $code_id: a conflict is a deny until resolved")
    [[ $code_verdict == allow ]] && code_verdict="review"
  fi
fi

# --- the stricter of the two governs ------------------------------------
rank() { case $1 in deny) echo 2;; review) echo 1;; *) echo 0;; esac; }
final=$code_verdict
if [[ $weight_verdict != "n/a" ]] && (( $(rank "$weight_verdict") > $(rank "$code_verdict") )); then
  final=$weight_verdict
fi

if [[ $mode == --json ]]; then
  printf '{\n  "code_license": "%s",\n  "code_verdict": "%s",\n' "$code_id" "$code_verdict"
  printf '  "weight_license": "%s",\n  "weight_verdict": "%s",\n  "weight_files": %s,\n' \
    "$weight_id" "$weight_verdict" "$weight_count"
  printf '  "declared_metadata": "%s",\n  "verdict": "%s",\n  "notes": [' "${declared:-}" "$final"
  for i in "${!notes[@]}"; do
    printf '%s"%s"' "$( ((i)) && echo ', ')" "$(printf '%s' "${notes[$i]}" | sed 's/"/\\"/g')"
  done
  printf ']\n}\n'
else
  printf 'licence gate: %s\n' "$(printf '%s' "$final" | tr '[:lower:]' '[:upper:]')"
  printf '  code    %-22s %s\n' "$code_id" "$code_verdict"
  [[ $weight_verdict != "n/a" ]] && printf '  weights %-22s %s  (%s file(s))\n' "$weight_id" "$weight_verdict" "$weight_count"
  [[ -n $declared ]] && printf '  declared %s\n' "$declared"
  ((${#notes[@]})) && { printf '\n'; for n in "${notes[@]}"; do printf '  - %s\n' "$n"; done; }
fi

case $final in allow) exit 0;; review) exit 10;; deny) exit 20;; esac
