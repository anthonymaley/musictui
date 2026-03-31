---
name: shuffle
description: "Toggle shuffle on/off"
disable-model-invocation: true
---

!`CEOL="${CEOL:-ceol}"
if command -v "$CEOL" &>/dev/null; then
    CURRENT=$(osascript -e 'tell application "Music" to get shuffle enabled' 2>/dev/null)
    if [ "$CURRENT" = "true" ]; then
        $CEOL shuffle off
    else
        $CEOL shuffle on
    fi
else
    osascript -e 'tell application "Music"
        if shuffle enabled then
            set shuffle enabled to false
            return "Shuffle off"
        else
            set shuffle enabled to true
            return "Shuffle on"
        end if
    end tell' 2>/dev/null
fi`
