#!/bin/bash
set -e
cd "$(dirname "$0")"
echo "🚀 Starting installation..."

echo "0. Testing the transcript merge and corrections..."
# A change that alters dictation output stops here until its new output is accepted (tests/run.sh --update).
tests/run.sh

echo "1. Building VoiceAgent.app..."
# An app bundle launched via `open` owns its microphone/speech permissions; a bare CLI inherits the
# launching app's (e.g. VS Code), whose Info.plist lacks NSSpeechRecognitionUsageDescription, so TCC aborts it.
APP=~/Applications/VoiceAgent.app
mkdir -p "$APP/Contents/MacOS"
cp swift-cli/Info.plist "$APP/Contents/Info.plist"
swiftc swift-cli/*.swift -o "$APP/Contents/MacOS/voice-agent" \
  -framework Cocoa \
  -framework Speech \
  -framework AVFoundation
scripts/sign.sh "$APP"

# The recorder puts this token in every vscode:// link and the extension rejects links without it.
DATA=~/.local/share/voice-agent
mkdir -p "$DATA"
if [ ! -s "$DATA/uri-token" ]; then
    (umask 077; openssl rand -hex 32 > "$DATA/uri-token")
fi

echo "2. Installing Whisper for Thai/English transcription..."
# Optional: without whisper-cli or the models, voice-agent falls back to Apple's recognizer text.
download() { # url, destination
    [ -f "$2" ] || { curl -fL -o "$2.part" "$1" && mv "$2.part" "$2"; } || echo "⚠️  Could not download $(basename "$2")"
}
if command -v brew &> /dev/null; then
    brew list whisper-cpp &> /dev/null || brew install whisper-cpp || echo "⚠️  whisper-cpp not installed"
    download https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin \
        "$DATA/ggml-large-v3-q5_0.bin"
    download https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin \
        "$DATA/ggml-silero-v5.1.2.bin"
else
    echo "⚠️  Homebrew not found: skipping Whisper (Apple's recognizer only)"
fi

echo "2b. Installing the speaker gate (only your voice reaches Whisper)..."
# Optional: without these files, or a voiceprint, Whisper hears everything. Apple silicon only.
SPEAKER=$DATA/speaker
mkdir -p "$SPEAKER"
download https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx \
    "$SPEAKER/campplus.onnx"
if [ ! -f "$SPEAKER/libsherpa-onnx-c-api.dylib" ] || [ ! -f "$SPEAKER/libonnxruntime.dylib" ]; then
    download https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts-lib.tar.bz2 \
        "$SPEAKER/sherpa-onnx.tar.bz2"
    tar xjf "$SPEAKER/sherpa-onnx.tar.bz2" -C "$SPEAKER" --strip-components 2 \
        '*/lib/libsherpa-onnx-c-api.dylib' '*/lib/libonnxruntime.dylib' || echo "⚠️  Could not unpack sherpa-onnx"
    rm -f "$SPEAKER/sherpa-onnx.tar.bz2"
fi
[ -f "$SPEAKER/voiceprint.f32" ] || echo "ℹ️  Speaker gate off until you enroll: see README, Speaker gate"

# Install common vocabulary without overwriting user settings.
mkdir -p ~/.config/voice-agent
cp scripts/vocabulary.txt ~/.config/voice-agent/common.txt
mkdir -p ~/.config/voice-agent/work
[ -f ~/.config/voice-agent/microphones.txt ] || cp scripts/microphones.txt ~/.config/voice-agent/microphones.txt

echo "3. Installing Toggle Script to ~/.local/bin/..."
mkdir -p ~/.local/bin
cp scripts/toggle-voice.sh ~/.local/bin/toggle-voice.sh
chmod +x ~/.local/bin/toggle-voice.sh

echo "4. Installing Control-Option-Space hotkey listener (LaunchAgent)..."
AGENT=~/Library/LaunchAgents/com.local.voiceagent.hotkey.plist
mkdir -p ~/Library/LaunchAgents
cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.local.voiceagent.hotkey</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/MacOS/voice-agent</string>
        <string>hotkey</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/voice-agent-hotkey.log</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null || true
# bootout returns before the old job is gone; bootstrap fails with "Input/output error" until then.
for attempt in 1 2 3 4 5; do
    launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null && break
    [ "$attempt" = 5 ] && { echo "❌ launchctl bootstrap failed"; exit 1; }
    sleep 1
done

echo "5. Building VS Code Extension..."
cd vscode-extension
npm install
npm run build
npx --yes @vscode/vsce@3.2.1 package --allow-missing-repository --skip-license
if command -v code &> /dev/null; then
    code --install-extension voice-agent-terminal-1.0.0.vsix --force
    # An open window keeps running the extension it loaded; until it reloads, dictation reports "no ack".
    echo "⚠️  In every open VS Code window: ⌘⇧P → Developer: Reload Window"
else
    echo "⚠️  'code' CLI not found: install vscode-extension/voice-agent-terminal-1.0.0.vsix from VS Code"
fi
cd ..

echo "6. Installing the vocabulary learner (automatic learning is paused)..."
# A copy outside ~/Desktop: a background job reading the Desktop makes macOS ask for folder access.
LEARN=$DATA/learn
mkdir -p "$LEARN/tests" "$LEARN/swift-cli"
rm -f "$LEARN/VoiceAgentCLI.swift" # the app source before it was split into swift-cli/*.swift
# Each file replaced whole (copy, then rename): a round may be running and read them.
for file in scripts/learn.py swift-cli/*.swift tests/*.py tests/*.tsv; do
    target=$LEARN/${file#scripts/} # learn.py at the top, tests/ and swift-cli/ as they are here
    cp "$file" "$target.new"
    mv "$target.new" "$target"
done
LEARNER=~/Library/LaunchAgents/com.local.voiceagent.learn.plist
launchctl disable "gui/$(id -u)/com.local.voiceagent.learn"
launchctl bootout "gui/$(id -u)" "$LEARNER" 2>/dev/null || true

echo "7. Installing the MCP server (agents can listen to you and speak back)..."
# Copied outside ~/Desktop like the learner: an agent's background process reading the Desktop makes macOS ask.
mkdir -p "$DATA/mcp"
cp mcp/server.mjs "$DATA/mcp/server.mjs.new"
mv "$DATA/mcp/server.mjs.new" "$DATA/mcp/server.mjs"
if command -v claude >/dev/null; then
    claude mcp remove --scope user voice-agent >/dev/null 2>&1 || true
    claude mcp add --scope user voice-agent -- node "$DATA/mcp/server.mjs"
else
    echo "⚠️  'claude' CLI not found: add the stdio server 'node $DATA/mcp/server.mjs' to your agent by hand"
fi

echo "🎉 Installation complete! Press Control-Option-Space: tap to type, hold to send, Esc to cancel."
echo "   Automatic vocabulary learning is paused; edit user.txt or work/<name>.txt in ~/.config/voice-agent/."
