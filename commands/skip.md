---
name: skip
description: Skip to next track in Apple Music
disable-model-invocation: true
---

!`CEOL="${CEOL:-ceol}"
if command -v "$CEOL" &>/dev/null; then
    $CEOL skip
else
    osascript -e 'tell application "Music"
        next track
        delay 0.5
        return "⏭ " & name of current track & " — " & artist of current track
    end tell' 2>/dev/null || echo "Could not skip"
fi`
