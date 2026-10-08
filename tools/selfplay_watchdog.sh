#!/bin/bash
# tools/selfplay_watchdog.sh -- keep the in-game self-player running unattended until 07:00 (launch it HIDDEN, see CLAUDE.md).
# Relaunches Balatro with bes_autostart on crash / stall / loop; gives up after 3 failed relaunches in a row.
# Self-play watchdog v2: restart on crash, stall (no self-play log line for 6 min) or LOOP (the newest 300 log lines
# hold <= 4 distinct messages -- v1 missed a 2-hour "target 3 card(s) for The Star" loop because the log kept growing).
LOG=/tmp/bes/watchdog.log
APLOG="$APPDATA/Balatro/bes_autoplay.log"
MODS="$APPDATA/r2modmanPlus-local/Balatro/profiles/Default/mods"
STALL=360
BASE=$(wc -l < "$APLOG")
FAILS=0
relaunch() {
  FAILS=$((FAILS + 1))
  if [ $FAILS -gt 3 ]; then   # 3 relaunches in a row without the game coming back: stop (2026-10-08: retrying every
    # 100 s for 2 hours while the PC was out of memory made it worse and filled the screen with error popups)
    echo "$(date +%H:%M:%S) GIVING UP after 3 failed relaunches ($1)" >> $LOG; echo done > /tmp/bes/selfplay_done; exit 1
  fi
  echo "$(date +%H:%M:%S) RELAUNCH ($1)" >> $LOG
  taskkill //IM Balatro.exe //F >/dev/null 2>&1; sleep 8
  touch "$APPDATA/Balatro/bes_autostart"
  "/c/Program Files (x86)/Steam/steam.exe" -applaunch 2379780 --mod-dir "$(cygpath -w "$MODS")" >/dev/null 2>&1 &
  sleep 90
  BASE=$(wc -l < "$APLOG")
}
echo "$(date +%H:%M:%S) watchdog v2 start" >> $LOG
while true; do
  if [ "$(date +%H)" = "07" ]; then
    echo "$(date +%H:%M:%S) 07:00 reached -- closing Balatro, watchdog done" >> $LOG
    taskkill //IM Balatro.exe >/dev/null 2>&1; sleep 10; taskkill //IM Balatro.exe //F >/dev/null 2>&1
    echo done > /tmp/bes/selfplay_done; exit 0
  fi
  if ! tasklist 2>/dev/null | grep -qi "Balatro.exe"; then relaunch "game not running"; continue; fi
  age=$(( $(date +%s) - $(stat -c %Y "$APLOG") ))
  if [ $age -gt $STALL ]; then relaunch "no self-play activity for ${age}s"; continue; fi
  N=$(wc -l < "$APLOG")
  if [ $((N - BASE)) -gt 300 ]; then
    distinct=$(tail -n 300 "$APLOG" | cut -c10- | sort -u | wc -l)
    if [ $distinct -le 4 ]; then relaunch "self-play looping (last 300 log lines: $distinct distinct messages)"; continue; fi
  fi
  [ $((N - BASE)) -gt 50 ] && FAILS=0   # the game is playing again: reset the failure count
  sleep 60
done
