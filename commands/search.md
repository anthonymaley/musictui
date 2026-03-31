---
name: search
description: "Search the Apple Music catalog. /music:search Bohemian Rhapsody"
arguments:
  - name: query
    description: "Song, artist, or album to search for"
    required: true
disable-model-invocation: true
---

!`CEOL="${CEOL:-ceol}"
if command -v "$CEOL" &>/dev/null; then
    $CEOL search $ARGUMENTS
else
    echo "Catalog search requires the ceol CLI. Run: scripts/install.sh"
fi`
