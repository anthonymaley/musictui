---
name: pause
description: Pause Apple Music playback
disable-model-invocation: true
---

!`CEOL="${CEOL:-ceol}"
if command -v "$CEOL" &>/dev/null; then
    $CEOL pause
else
    osascript -e 'tell application "Music"
        pause
        return "⏸ Paused — " & name of current track & " — " & artist of current track
    end tell' 2>/dev/null || echo "Could not pause"
fi`
