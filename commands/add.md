---
name: add
description: "Add a track to your Apple Music library. /music:add Get It Done Fouk"
arguments:
  - name: query
    description: "Song title and/or artist to search and add"
    required: true
disable-model-invocation: true
---

!`CEOL="${CEOL:-ceol}"
if command -v "$CEOL" &>/dev/null; then
    $CEOL add $ARGUMENTS
else
    echo "Adding to library requires the ceol CLI. Run: scripts/install.sh"
fi`
