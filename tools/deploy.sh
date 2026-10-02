#!/usr/bin/env bash
# Sync the repo's mod files into the live install. Run from the repo root.
#
#   bash tools/deploy.sh            # sync every target
#   bash tools/deploy.sh --check    # report drift only, change nothing
#   bash tools/deploy.sh --no-legacy  # skip the plain-Steam-launch fallback copy
#
# TWO targets, both deliberate:
#   1. the r2modman profile  -- what a normal (r2modman) launch loads
#   2. %APPDATA%/Balatro/Mods -- what Lovely falls back to when Balatro is
#      started straight from Steam with no --mod-dir. Leaving it behind means a
#      plain launch silently runs STALE code, which is the whole hazard CLAUDE.md
#      warns about, so it is kept current rather than left to rot.
#
# Why a script at all: CLAUDE.md's own lesson is that hand-copying "just the
# files you edited" silently drifted the install by SIX files. This mirrors the
# whole tree, including DELETIONS -- which matters more than it sounds, e.g.
# ui/hud_inject.lua was replaced by ui/hud_panel.lua, and a leftover .lua still
# gets loaded.
set -euo pipefail

[ -f your_mod.json ] || { echo "run me from the repo root" >&2; exit 1; }

VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' your_mod.json | head -1)"
[ -n "$VERSION" ] || { echo "could not read version from your_mod.json" >&2; exit 1; }

PROFILE="${BES_R2_PROFILE:-$APPDATA/r2modmanPlus-local/Balatro/profiles/Default}"
R2_DEST="$PROFILE/mods/balatroenginesim"
R2_CACHE="${BES_R2_CACHE:-$APPDATA/r2modmanPlus-local/Balatro/cache/balatroenginesim/$VERSION}"
LEGACY_DEST="${BES_LEGACY_DEST:-$APPDATA/Balatro/Mods/balatroenginesim}"

CHECK=0; LEGACY=1
for a in "$@"; do
  case "$a" in
    --check)      CHECK=1 ;;
    --no-legacy)  LEGACY=0 ;;
    *) echo "unknown flag: $a" >&2; exit 1 ;;
  esac
done

[ -d "$PROFILE/mods" ] || { echo "no r2modman profile at $PROFILE" >&2; exit 1; }

# The deployed set: everything the game needs, minus repo-only research material.
mod_files() {
  git ls-files \
    ':!:sim/*' ':!:tools/*' ':!:data/*' ':!:sim_out/*' ':!:docs/*' \
    ':!:.agents/*' ':!:.claude/*' ':!:NEXT_SESSION.md'
}

# Mirror the tracked set into $1. Echoes one line per file it had to touch.
sync_into() {
  local dest="$1" cache="${2:-}" label="$3" n=0
  while IFS= read -r f; do
    # --strip-trailing-cr: the checkout is CRLF and the install LF, so a byte
    # compare reports false differences (noted in CLAUDE.md).
    if ! diff -q --strip-trailing-cr "$f" "$dest/$f" >/dev/null 2>&1; then
      echo "  DRIFT  $label  $f"; n=$((n + 1))
      if [ "$CHECK" = 0 ]; then
        mkdir -p "$dest/$(dirname "$f")"; cp -p "$f" "$dest/$f"
        [ -n "$cache" ] && { mkdir -p "$cache/$(dirname "$f")"; cp -p "$f" "$cache/$f"; }
      fi
    fi
  done < <(mod_files)

  # Files the install has but the repo no longer tracks.
  if [ -d "$dest" ]; then
    local tracked; tracked="$(mod_files)"
    while IFS= read -r g; do
      case "$g" in manifest.json) continue ;; esac   # r2modman's own, not ours
      if ! printf '%s\n' "$tracked" | grep -qxF "$g"; then
        echo "  STALE  $label  $g"; n=$((n + 1))
        [ "$CHECK" = 0 ] && rm -f "$dest/$g" ${cache:+"$cache/$g"}
      fi
    done < <(cd "$dest" && find . -type f | sed 's|^\./||' | sort)
  fi
  echo "$n" > "$TMP_N"
}

TMP_N="$(mktemp)"; trap 'rm -f "$TMP_N"' EXIT
total=0

sync_into "$R2_DEST" "$R2_CACHE" "r2modman"; total=$((total + $(cat "$TMP_N")))
r2_drift=$(cat "$TMP_N")

if [ "$LEGACY" = 1 ]; then
  sync_into "$LEGACY_DEST" "" "legacy  "; total=$((total + $(cat "$TMP_N")))
fi

echo "---"
if [ "$total" = 0 ]; then
  echo "all targets current ($(mod_files | wc -l | tr -d ' ') files, v$VERSION)"
  exit 0
fi

if [ "$CHECK" = 1 ]; then
  echo "$total file(s) differ -- re-run without --check to sync"
  exit 1
fi

echo "synced $total file(s), v$VERSION"

# Any add/remove makes r2modman's own file manifest stale, which breaks its
# enable/disable and uninstall. Rebuild it from what is now on disk.
if [ "$r2_drift" != 0 ]; then
  python tools/r2modman_state.py "$VERSION"
fi
