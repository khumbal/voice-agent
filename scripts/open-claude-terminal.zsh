#!/bin/zsh
# Opens a new VS Code terminal tab in <dir> (default: the current directory) and runs Claude Code there, through the
# voice-agent-terminal extension's /terminal URI. Prints the extension's answer, or "no ack" when none came back
# (the window has not been reloaded since the extension was installed, or VS Code is not running).
#   open-claude-terminal.zsh [dir]
dir=${1:-$PWD}
dir=${dir:A}
app=${VOICE_AGENT_VSCODE_APP:-Visual Studio Code}
data=$HOME/.local/share/voice-agent
# The extension compares against the file trimmed.
token=$(tr -d '[:space:]' < $data/uri-token 2>/dev/null)
[[ -n $token ]] || { print -u2 "no token at $data/uri-token"; exit 2 }
ack=$(uuidgen | tr -d '-' | tr 'A-F' 'a-f')
# base64url: VS Code hands the extension an already percent-decoded query, so '&', '+' or '%' in a path would not
# survive. until = 0.5 s before this script stops waiting: after it the extension refuses rather than open a tab this
# script has reported as failed.
cwd=$(python3 -I -c 'import sys, base64; print(base64.urlsafe_b64encode(sys.argv[1].encode()).decode().rstrip("="))' $dir)
[[ -n $cwd ]] || { print -ru2 -- "could not encode $dir"; exit 2 }
zmodload zsh/datetime
until=${$(( EPOCHREALTIME * 1000 + 4500 ))%.*}
open -a $app "vscode://local.voice-agent-terminal/terminal?cwd=${cwd}&until=${until}&token=${token}&ack=${ack}" \
  || exit 2
for i in {1..50}; do
  if [[ -f $data/ack/$ack ]]; then
    outcome=$(<$data/ack/$ack)
    rm -f $data/ack/$ack
    print -r -- $outcome
    [[ $outcome == error* ]] && exit 1
    exit 0
  fi
  sleep 0.1
done
print -u2 "no ack"
exit 1
