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
# Since 2026-10-02 the mod is the r2modman-IMPORTED package (tools/package_r2.py zip) at mods/Anto640-EngineSim;
# the older hand-registered local mod lived at mods/balatroenginesim. Deploy to whichever one exists -- never both
# (two copies inside mods/ load as two conflicting instances of the mod).
if [ -d "$PROFILE/mods/Anto640-EngineSim" ] && [ -d "$PROFILE/mods/balatroenginesim" ]; then
  echo "TWO copies of the mod in $PROFILE/mods (Anto640-EngineSim and balatroenginesim) -- remove one first" >&2; exit 1
fi
if [ -d "$PROFILE/mods/Anto640-EngineSim" ]; then R2_NAME="Anto640-EngineSim"; PACKAGED=1
else R2_NAME="balatroenginesim"; PACKAGED=0; fi
R2_DEST="$PROFILE/mods/$R2_NAME"
# r2modman RESTORES a mod from cache/<name>/<registered version> on every launch -- the version in the installed
# manifest.json (what was imported), NOT your_mod.json's. Writing only to cache/<repo version> was silently undone at
# launch (2026-10-04: install back at the imported 0.5.0, so F5 still kept 12 and two days of fixes never ran live).
R2_VER="$VERSION"
if [ "$PACKAGED" = 1 ] && [ -f "$R2_DEST/manifest.json" ]; then
  R2_VER=$(sed -n 's/.*"version_number"[^"]*"\([^"]*\)".*/\1/p' "$R2_DEST/manifest.json" | head -1)
  R2_VER="${R2_VER:-$VERSION}"
fi
R2_CACHE="${BES_R2_CACHE:-$APPDATA/r2modmanPlus-local/Balatro/cache/$R2_NAME/$R2_VER}"
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

# The deployed set: everything the game needs, minus repo-only research material. For the imported PACKAGE it is
# exactly what tools/package_r2.py ships (the mod's code + main.lua, your_mod.json, config.lua), so the install
# stays the same shape as the zip a friend imports.
mod_files() {
  if [ "${PACKAGED:-0}" = 1 ]; then
    git ls-files core engine model ui util main.lua your_mod.json config.lua
    return
  fi
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
      if [ "$CHECK" = 0 ]; then mkdir -p "$dest/$(dirname "$f")"; cp -p "$f" "$dest/$f"; fi
    fi
    # the cache is checked on its own: r2modman restores the install FROM it at launch, so a stale cache undoes a
    # deploy even when the install itself is current
    if [ -n "$cache" ] && ! diff -q --strip-trailing-cr "$f" "$cache/$f" >/dev/null 2>&1; then
      echo "  DRIFT  $label-cache  $f"; n=$((n + 1))
      if [ "$CHECK" = 0 ]; then mkdir -p "$cache/$(dirname "$f")"; cp -p "$f" "$cache/$f"; fi
    fi
  done < <(mod_files)

  # Files the install has but the repo no longer tracks.
  if [ -d "$dest" ]; then
    local tracked; tracked="$(mod_files)"
    while IFS= read -r g; do
      case "$g" in manifest.json|icon.png|mm_v2_manifest.json|README.md) continue ;; esac   # r2modman / package files, not ours
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
  if [ "$PACKAGED" = 1 ]; then
    # r2modman_state.py is for the old local-mod registration. For the imported package, a deploy that ADDS or
    # REMOVES files leaves r2modman's per-file list stale (only its disable / uninstall care); re-importing a
    # fresh `python tools/package_r2.py` zip refreshes it.
    echo "(packaged install: if files were added or removed, re-import python tools/package_r2.py's zip to refresh r2modman's file list)"
  else
    python tools/r2modman_state.py "$VERSION"
  fi
fi
