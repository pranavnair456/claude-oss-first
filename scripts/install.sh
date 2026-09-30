#!/usr/bin/env bash
# Fallback installer for people not using the plugin system.
#
#   install.sh            symlink skills + commands into ~/.claude
#   install.sh --uninstall
#
# The supported path is the plugin:
#   /plugin marketplace add pranavnair456/claude-oss-first
#   /plugin install oss-first
# This exists for a machine where that is unavailable, and for testing local
# edits without publishing.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
dest="${CLAUDE_HOME:-$HOME/.claude}"

if [[ ${1:-} == --uninstall ]]; then
  for d in "$dest/skills" "$dest/commands"; do
    [[ -d $d ]] || continue
    find "$d" -maxdepth 1 -type l | while read -r l; do
      [[ $(readlink "$l") == "$here"/* ]] && { rm "$l"; printf 'removed %s\n' "$l"; }
    done
  done
  printf 'done. The quarantine at %s/oss-sandbox was left alone.\n' "$dest"
  exit 0
fi

mkdir -p "$dest/skills" "$dest/commands"
for s in "$here"/skills/*/; do
  n=$(basename "$s"); ln -sfn "${s%/}" "$dest/skills/$n"; printf 'skill    %s\n' "$n"
done
for c in "$here"/commands/*.md; do
  n=$(basename "$c"); ln -sfn "$c" "$dest/commands/$n"; printf 'command  /%s\n' "${n%.md}"
done

mkdir -p "$dest/oss-sandbox"
cat > "$dest/oss-sandbox/README.md" <<'MD'
# Quarantine

Unreviewed third-party code, cloned here so it is nowhere near a project tree.

Nothing here is trusted. Nothing here is executable - the execute bit is
stripped at clone time and `.git/hooks` is deleted. Everything here is
disposable: delete any directory at any time.

Read it, grep it, hash it, scan it. Do not build it, install it or run it. If
something genuinely has to execute, use a container with no network and a
read-only mount:

    docker run --rm --network none -v <dir>:/src:ro -w /src <image> <cmd>

Created by the oss-first plugin.
MD

printf '\nlinked into %s\n' "$dest"
printf 'quarantine ready at %s/oss-sandbox\n' "$dest"
printf '\nNote: the PreToolUse quarantine guard ships with the plugin, not with\n'
printf 'this symlink install. Register it by hand in settings.json if you need it:\n'
printf '  %s/hooks/quarantine-guard.sh\n' "$here"
