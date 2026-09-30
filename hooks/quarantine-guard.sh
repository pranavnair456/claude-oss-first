#!/usr/bin/env bash
# PreToolUse guard: nothing in quarantine gets built, installed or executed.
#
# "Clone it into a sandbox so it can't touch anything on your machine" is only
# true if something enforces it. Stripping the execute bit at clone time stops
# an accident; this stops a decision. Reading, grepping, hashing and scanning
# the tree stay allowed, because that is the entire job of the vet stage.
#
# Reads the hook payload on stdin, emits a PreToolUse decision on stdout.
set -uo pipefail

allow() { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'; exit 0; }
pass()  { exit 0; }   # no opinion: let the normal permission flow handle it

payload=$(cat 2>/dev/null) || pass
command -v jq >/dev/null 2>&1 || pass

tool=$(jq -r '.tool_name // ""' <<<"$payload" 2>/dev/null) || pass
[[ $tool == "Bash" ]] || pass

cmd=$(jq -r '.tool_input.command // ""' <<<"$payload" 2>/dev/null)
cwd=$(jq -r '.cwd // ""' <<<"$payload" 2>/dev/null)
[[ -n $cmd ]] || pass

sandbox="${OSS_SANDBOX:-$HOME/.claude/oss-sandbox}"
# Match the literal path, a ~ form, or the env var - and also catch the case
# where the session's own cwd is already inside quarantine.
touches_quarantine=0
case "$cmd" in
  *"$sandbox"*|*'~/.claude/oss-sandbox'*|*'$OSS_SANDBOX'*|*'.claude/oss-sandbox'*) touches_quarantine=1 ;;
esac
case "$cwd" in
  "$sandbox"/*|"$sandbox") touches_quarantine=1 ;;
esac
(( touches_quarantine )) || pass

# The vet stage's own tooling is what is *supposed* to run against quarantine.
case "$cmd" in
  *security-scan.sh*|*license-gate.sh*|*sandbox-clone.sh*|*collect-licenses.py*|*gh-recon.sh*) pass ;;
esac

# Verbs that install, build or execute. Anything not on this list is reading,
# and reading is the point.
deny_reason=""
# Pairs, not a delimited file: every regex below contains | for alternation.
DENY_RULES=(
  '(^|[;&|[:space:]])(pip|pip3|pipx)[[:space:]]+install'                      'pip install would run the package'"'"'s own build code'
  '(^|[;&|[:space:]])uv[[:space:]]+(sync|pip|run|add)'                        'uv would resolve and build from this tree'
  '(^|[;&|[:space:]])(npm|pnpm|yarn|bun)[[:space:]]+(i|install|ci|add|run|exec|start|test)' 'a node install runs preinstall/postinstall scripts'
  '(^|[;&|[:space:]])(poetry|pdm|hatch|conda)[[:space:]]+(install|add|sync|run)' 'the package manager would build from this tree'
  '(^|[;&|[:space:]])(make|cmake|ninja|meson|gradle|mvn|bazel)([[:space:]]|$)' 'a build runs arbitrary rules from this tree'
  '(^|[;&|[:space:]])\./(configure|setup\.py|install\.sh|build\.sh|bootstrap)' 'executing an upstream script'
  '(^|[;&|[:space:]])(python|python3|node|deno|ruby|perl|php)[[:space:]]+[^-][^[:space:]]*\.(py|js|mjs|cjs|ts|rb|pl|php)' 'running upstream source directly'
  '(^|[;&|[:space:]])(bash|sh|zsh|source)[[:space:]]+[^-][^[:space:]]*\.(sh|bash|zsh)' 'shelling an upstream script'
  '(^|[;&|[:space:]])(cargo|go)[[:space:]]+(run|build|install|test)'          'a compile runs build scripts from this tree'
  '(^|[;&|[:space:]])setup\.py'                                              'setup.py is executable Python, not a manifest'
  '(^|[;&|[:space:]])chmod[[:space:]]+[^;|&]*\+x'                            'restoring the execute bit undoes the quarantine hardening'
  '(^|[;&|[:space:]])(docker|podman)[[:space:]]+build'                        'a docker build executes the upstream Dockerfile'
  '(^|[;&|[:space:]])git[[:space:]]+(submodule|lfs)'                          'pulling submodules or LFS payloads fetches unvetted content'
)
for ((i=0; i<${#DENY_RULES[@]}; i+=2)); do
  if printf '%s' "$cmd" | grep -qE "${DENY_RULES[i]}"; then
    deny_reason="${DENY_RULES[i+1]}"; break
  fi
done

[[ -z $deny_reason ]] && pass

jq -nc \
  --arg reason "BLOCKED by oss-first quarantine guard: $deny_reason.

Quarantine is read-only by design: $sandbox
Nothing there has been vetted, and nothing there is meant to run.

What to do instead:
  - Static analysis is already allowed. Run the suite:
      security-scan.sh <quarantine-dir>
  - If it genuinely has to execute, use a container with no network and a
    read-only mount, which is the only sanctioned way:
      docker run --rm --network none -v <quarantine-dir>:/src:ro -w /src <image> <cmd>
  - If it has passed the suite and you are adopting it, install it from its
    registry into the *project*, not from the quarantined clone." \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
exit 0
