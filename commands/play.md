---
name: play
description: "Resume or play a playlist/artist/album/song, optionally on a speaker at a volume. /music:play [query] [speaker] [volume%]"
arguments:
  - name: query
    description: "Playlist name, artist, album, or song. Optionally add a speaker name and volume%. Empty to resume."
    required: false
disable-model-invocation: true
---

!`MUSIC_CLI="${MUSIC_CLI:-music}"

if ! command -v "$MUSIC_CLI" &>/dev/null; then
    osascript -e 'tell application "Music"
        play
        return "▶ " & name of current track & " — " & artist of current track
    end tell' 2>/dev/null || echo "music CLI not installed. Run: scripts/install.sh"
    exit 0
fi

# The CLI's own smart parser handles speaker names and volumes natively
# (this command used to re-implement that matching in bash, which drifted
# and lowercased playlist names). Only the %-suffix needs stripping.
ARGS=$(echo "$ARGUMENTS" | sed -E 's/([0-9]+)%/\1/g')
$MUSIC_CLI play $ARGS`
