---
name: speaker
description: "Switch or manage AirPlay speakers. /music:speaker kitchen, /music:speaker only kitchen, /music:speaker add bedroom, /music:speaker remove kitchen, /music:speaker remove kitchen add julie office, /music:speaker list"
arguments:
  - name: action
    description: "Speaker name, 'add <name>', 'remove <name>', 'only <name>', 'airpods', 'list'. Chain actions: 'remove kitchen add bedroom'"
    required: false
disable-model-invocation: true
---

!`INPUT="$ARGUMENTS"
if [ -z "$INPUT" ]; then INPUT="list"; fi

LOWER_INPUT=$(echo "$INPUT" | tr "[:upper:]" "[:lower:]")

# Handle list
if [ "$LOWER_INPUT" = "list" ]; then
    osascript -e 'tell application "Music"
        set deviceList to every AirPlay device
        set output to ""
        repeat with d in deviceList
            set marker to "  "
            if selected of d then set marker to "▶ "
            set output to output & marker & name of d & " [" & sound volume of d & "]" & linefeed
        end repeat
        return output
    end tell' 2>/dev/null
    exit 0
fi

# Handle airpods
if [ "$LOWER_INPUT" = "airpods" ]; then
    DEVICES=$(osascript -e 'tell application "Music" to get name of every AirPlay device' 2>/dev/null)
    MATCH=$(echo "$DEVICES" | tr "," "\n" | sed "s/^ *//" | grep -i "airpods" | head -1)
    if [ -n "$MATCH" ]; then
        osascript -e "tell application \"Music\"
            set allDevices to every AirPlay device
            repeat with d in allDevices
                set selected of d to false
            end repeat
            set selected of AirPlay device \"$MATCH\" to true
        end tell" 2>/dev/null
        echo "🎧 $MATCH"
    else
        echo "No AirPods found — check Bluetooth"
    fi
    exit 0
fi

DEVICES=$(osascript -e 'tell application "Music" to get name of every AirPlay device' 2>/dev/null)
find_match() { echo "$DEVICES" | tr "," "\n" | sed "s/^ *//" | grep -i "$1" | head -1; }
show_active() {
    osascript -e 'tell application "Music"
        set deviceList to every AirPlay device
        set output to ""
        repeat with d in deviceList
            if selected of d then
                if output is not "" then set output to output & ", "
                set output to output & name of d & " [" & sound volume of d & "]"
            end if
        end repeat
        return "🔊 " & output
    end tell' 2>/dev/null
}

# Parse chained actions by splitting on action keywords
# e.g. "remove kitchen add julie office" → "remove kitchen" + "add julie office"
# e.g. "only kitchen" → "only kitchen"
# e.g. "kitchen" (bare name) → "only kitchen"
ACTIONS=""
CURRENT_ACTION=""
for word in $INPUT; do
    w_lower=$(echo "$word" | tr "[:upper:]" "[:lower:]")
    case "$w_lower" in
        add|remove|only)
            if [ -n "$CURRENT_ACTION" ]; then
                ACTIONS="${ACTIONS}${ACTIONS:+|}${CURRENT_ACTION}"
            fi
            CURRENT_ACTION="$w_lower"
            ;;
        *)
            CURRENT_ACTION="${CURRENT_ACTION}${CURRENT_ACTION:+ }${word}"
            ;;
    esac
done
if [ -n "$CURRENT_ACTION" ]; then
    ACTIONS="${ACTIONS}${ACTIONS:+|}${CURRENT_ACTION}"
fi

# Process each action
IFS='|' read -ra ACTION_LIST <<< "$ACTIONS"
for action_entry in "${ACTION_LIST[@]}"; do
    ACTION_WORD=$(echo "$action_entry" | awk '{print $1}' | tr "[:upper:]" "[:lower:]")
    SPEAKER_NAME=$(echo "$action_entry" | sed 's/^[^ ]* *//')
    case "$ACTION_WORD" in
        add)
            MATCH=$(find_match "$SPEAKER_NAME")
            if [ -n "$MATCH" ]; then
                osascript -e "tell application \"Music\" to set selected of AirPlay device \"$MATCH\" to true" 2>/dev/null
            else
                echo "No device matching: $SPEAKER_NAME"
            fi
            ;;
        remove)
            MATCH=$(find_match "$SPEAKER_NAME")
            if [ -n "$MATCH" ]; then
                osascript -e "tell application \"Music\" to set selected of AirPlay device \"$MATCH\" to false" 2>/dev/null
            else
                echo "No device matching: $SPEAKER_NAME"
            fi
            ;;
        only)
            MATCH=$(find_match "$SPEAKER_NAME")
            if [ -n "$MATCH" ]; then
                osascript -e "tell application \"Music\"
                    set allDevices to every AirPlay device
                    repeat with d in allDevices
                        set selected of d to false
                    end repeat
                    set selected of AirPlay device \"$MATCH\" to true
                end tell" 2>/dev/null
            else
                echo "No device matching: $SPEAKER_NAME"
            fi
            ;;
        *)
            # Bare speaker name — treat as "only"
            MATCH=$(find_match "$action_entry")
            if [ -n "$MATCH" ]; then
                osascript -e "tell application \"Music\"
                    set allDevices to every AirPlay device
                    repeat with d in allDevices
                        set selected of d to false
                    end repeat
                    set selected of AirPlay device \"$MATCH\" to true
                end tell" 2>/dev/null
            else
                echo "No device matching: $action_entry"
            fi
            ;;
    esac
done

show_active`
