#!/bin/zsh
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# Match only the recording instance; the hotkey listener runs the same binary as "voice-agent hotkey".
RECORDER='VoiceAgent.app/Contents/MacOS/voice-agent (vscode|tmux)'

if pgrep -f "$RECORDER" > /dev/null; then
    pkill -INT -f "$RECORDER"
    exit 0
fi

# -n: the hotkey listener is already a running instance of this bundle
open -n -g "$HOME/Applications/VoiceAgent.app" --args vscode
