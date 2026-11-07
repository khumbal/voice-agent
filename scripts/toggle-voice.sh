#!/bin/zsh
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# The hotkey listener takes SIGUSR2 as a tap of the hotkey: it stops the recording that is listening, or wakes its
# standby recorder (no launch to wait for), and keeps track of both as it does for the hotkey.
if pkill -USR2 -f 'VoiceAgent.app/Contents/MacOS/voice-agent hotkey'; then
    exit 0
fi

# No listener: match only the recording instance.
RECORDER='VoiceAgent.app/Contents/MacOS/voice-agent (vscode|tmux)'

if pgrep -f "$RECORDER" > /dev/null; then
    pkill -INT -f "$RECORDER"
    exit 0
fi

open -n -g "$HOME/Applications/VoiceAgent.app" --args vscode
