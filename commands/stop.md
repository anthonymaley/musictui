---
name: stop
description: Stop Apple Music playback
disable-model-invocation: true
---

!`CEOL="${CEOL:-ceol}"
if command -v "$CEOL" &>/dev/null; then
    $CEOL stop
else
    osascript -e 'tell application "Music" to stop' 2>/dev/null && echo "■ Stopped" || echo "Could not stop"
fi`
