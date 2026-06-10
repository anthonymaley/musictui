---
name: repeat
description: "Set repeat mode: off, one, or all"
disable-model-invocation: true
arguments:
  - name: mode
    description: "off, one, or all"
    required: true
---

!`MUSIC_CLI="${MUSIC_CLI:-music}"
if command -v "$MUSIC_CLI" &>/dev/null; then
    $MUSIC_CLI repeat $ARGUMENTS
else
    MODE=$(echo "$ARGUMENTS" | tr '[:upper:]' '[:lower:]')
    osascript -e "tell application \"Music\"
        set song repeat to $MODE
        return \"Repeat $MODE\"
    end tell" 2>/dev/null
fi`
