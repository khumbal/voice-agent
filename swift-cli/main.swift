import Cocoa

let args = CommandLine.arguments
let modeArg = args.count > 1 ? args[1] : "vscode"

// Which microphone the next recording uses, and the names microphones.txt can list.
if modeArg == "microphones" {
    let microphones = Microphone.all()
    let chosen = Microphone.chosen(from: microphones, preferred: Config.preferredMicrophones)
    for microphone in microphones {
        print("\(microphone.id == chosen?.id ? "*" : " ") \(microphone.name) [\(microphone.transportCode)"
              + "\(microphone.isDefault ? ", default" : "")\(microphone.rank == nil ? ", only when named" : "")]")
    }
    exit(0)
}

// "enroll --mic <name> <wav>…": the speaker gate's voiceprint, from recordings of the user alone on that microphone
// (see SpeakerGate.enroll).
// "gate <wav> [out.wav]": how a run of that whole recording is gated on the enrolled microphone; out.wav gets the audio
// Whisper would hear. For checking Config.speakerThreshold on real recordings.
if modeArg == "enroll"
    ? args.count < 5 || args[2] != "--mic" || args[3].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    : modeArg == "gate" && args.count < 3 {
    print("usage: voice-agent enroll --mic <name> <wav>… | voice-agent gate <wav> [out.wav]")
    exit(1)
}
if modeArg == "enroll" {
    let result = SpeakerGate.enroll(Array(args.dropFirst(4)), microphone: args[3])
    print(result.message)
    exit(result.ok ? 0 : 1)
}
if modeArg == "gate" {
    guard let gate = SpeakerGate.shared, let samples = SpeakerGate.readWAV(args[2]) else {
        print("cannot gate: \(SpeakerGate.problem.isEmpty ? "not a 16 kHz mono WAV" : SpeakerGate.problem)")
        exit(1)
    }
    let result = gate.gate(samples)
    print("scores: \(AppDelegate.scoreList(result.scores))")
    print("silenced: " + result.silenced.map { String(format: "%.1f-%.1f s", Double($0.lowerBound) / 16000,
                                                      Double($0.upperBound) / 16000) }.joined(separator: ", "))
    if args.count > 3 {
        let out = result.kept ?? samples
        _ = AppDelegate.writeWAV(out, to: URL(fileURLWithPath: args[3]))
    }
    exit(0)
}

// "listen <id>": one recording whose result goes to Config.resultsDir/<id>.json, typed nowhere (mcp/server.mjs).
let resultID = modeArg == "listen" ? args.dropFirst(2).first : nil
if modeArg == "listen", resultID?.range(of: "^[A-Za-z0-9-]{1,64}$", options: .regularExpression) == nil {
    print("usage: voice-agent listen <id: letters, digits or -, at most 64>")
    exit(1)
}
// One `listen` on this Mac at a time, whichever program asks: two would fight over the microphone. flock, not a
// file's existence: the lock goes with this process however it ends, so none is ever left behind.
if let resultID {
    try? FileManager.default.createDirectory(atPath: Config.resultsDir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    let lock = open(Config.resultsDir + "/listen.lock", O_RDWR | O_CREAT, 0o600) // held open until exit
    guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
        TranscriptResult(outcome: .failed, error: "busy: another listen is recording").save(as: resultID)
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if modeArg == "hotkey" {
    guard ToggleHotkey.register() else {
        fputs("voice-agent: Control-Option-Space is already registered by another app\n", stderr)
        exit(1)
    }
    app.run()
} else {
    // "standby <listener pid>": launched by the hotkey listener ahead of the next press (see ToggleHotkey).
    let standbyFor = modeArg == "standby" ? args.dropFirst(2).first.flatMap { pid_t($0) } : nil
    let delegate = AppDelegate(mode: TargetMode(rawValue: modeArg) ?? .vscode, resultID: resultID,
                               standbyFor: standbyFor)
    // Before app.run, so the hotkey listener can signal as soon as the app reports it finished launching.
    delegate.setupSignalHandlers()
    app.delegate = delegate
    app.run()
}
