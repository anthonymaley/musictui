#!/bin/bash
# Gated live probe for the AirPlay verify-and-heal stack. Run BY HAND on a
# Mac with real speakers — it plays ~10s of audio on the named speaker.
# Usage: scripts/airplay-live-probe.sh [speaker-name]   (default: Kitchen)
set -euo pipefail
SPEAKER="${1:-Kitchen}"
MUSIC="swift run --package-path tools/music music"

echo "== 1. route + play + verify (expect: ✓ verified) =="
$MUSIC play in the "$SPEAKER"
sleep 2

echo "== 2. steady-state verify (expect: ✓) =="
$MUSIC speaker verify "$SPEAKER"

echo "== 3. route away (expect next verify to FAIL: lingering conns only) =="
# "MacBook" contains-matches the real device name — its curly apostrophe
# (Anthony's) makes the full name hostile to shell quoting.
$MUSIC speaker set "MacBook"
sleep 3
$MUSIC speaker verify "$SPEAKER" || true

echo "== 4. route back + verify + pause =="
$MUSIC play in the "$SPEAKER"
sleep 2
$MUSIC speaker verify "$SPEAKER"
$MUSIC pause
echo "== probe complete — read the ✓/✗ marks above =="
