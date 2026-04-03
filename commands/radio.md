---
name: radio
description: "Start a radio station from the currently playing track"
disable-model-invocation: true
---

!`MUSIC_CLI="${MUSIC_CLI:-music}"
if command -v "$MUSIC_CLI" &>/dev/null; then
    $MUSIC_CLI radio
else
    TRACK=$(osascript -e 'tell application "Music" to return name of current track & " — " & artist of current track' 2>/dev/null)
    if [ -z "$TRACK" ]; then
        echo "Nothing playing."
        exit 0
    fi
    osascript -e '
        tell application "System Events"
            tell process "Music"
                click menu item "Create Station" of menu "Song" of menu bar 1
            end tell
        end tell
    ' 2>/dev/null
    echo "Started radio station from: $TRACK"
fi`
