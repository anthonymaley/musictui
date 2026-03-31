---
name: similar
description: "Find tracks similar to what's playing. /music:similar"
arguments:
  - name: query
    description: "Optional: title and artist. Empty uses current track."
    required: false
disable-model-invocation: true
---

!`CEOL="${CEOL:-ceol}"
if command -v "$CEOL" &>/dev/null; then
    $CEOL similar $ARGUMENTS
else
    echo "Discovery requires the ceol CLI. Run: scripts/install.sh"
fi`
