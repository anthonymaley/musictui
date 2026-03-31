---
name: np
description: Show what's currently playing in Apple Music
disable-model-invocation: true
---

Now playing:

!`CEOL="${CEOL:-ceol}"
if command -v "$CEOL" &>/dev/null; then
    $CEOL now
else
    osascript -e 'tell application "Music"
        if player state is playing then
            return "▶ " & name of current track & " — " & artist of current track & " (" & album of current track & ")"
        else if player state is paused then
            return "⏸ " & name of current track & " — " & artist of current track & " (paused)"
        else
            return "■ Nothing playing"
        end if
    end tell' 2>/dev/null || echo "■ Music app not running"
fi`
