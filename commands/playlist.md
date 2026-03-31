---
name: playlist
description: "Manage playlists. /music:playlist list, /music:playlist tracks Working Vibes"
arguments:
  - name: action
    description: "list, tracks <name>, create <name>, delete <name>, add <playlist> <title> <artist>"
    required: true
disable-model-invocation: true
---

!`CEOL="${CEOL:-ceol}"
if command -v "$CEOL" &>/dev/null; then
    $CEOL playlist $ARGUMENTS
else
    echo "Playlist management requires the ceol CLI. Run: scripts/install.sh"
fi`
