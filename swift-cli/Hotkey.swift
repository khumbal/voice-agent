import Cocoa
import Carbon.HIToolbox

// System-wide hotkey: Carbon hotkeys fire before the focused app sees the key, so it also works in VS Code's terminal.
// Tap: start a recording that ends on silence or the next press. Hold: push-to-talk, the release ends it.
// The recording runs as a separate instance of this bundle so it owns its microphone/speech permissions.
enum ToggleHotkey {
    static let holdThreshold: TimeInterval = 0.35
    private static var hotKeyRef: EventHotKeyRef?
    private static var pressedAt = Date.distantPast
    private static var startedOnPress = false
    // Until the recorder has finished launching it may be invisible or not yet handling signals (a signal then kills
    // it or is lost), so a press or release in that window is kept and delivered once it is up.
    private static var launching = false
    private static var pendingSignal: Int32?
    private static var signalled = Set<pid_t>() // recorders told to finish: transcribing, no longer listening
    // A recorder launched ahead and waiting off the microphone (see AppDelegate.wake): a press wakes it instead of
    // launching one, which took ~0.5 s. Never a recorder to signal: while one launches, nothing launched since counts.
    private static var standby: NSRunningApplication?
    private static var standbyLaunchedAt: Date?
    private static var launched: pid_t? // the last recorder launched on a press
    private static var toggleSource: DispatchSourceSignal?

    static func register() -> Bool {
        // SIGUSR2 from toggle-voice.sh: a tap of the hotkey. First, so only a toggle before this line (early in a
        // restart) still kills the listener; launchd starts it again.
        signal(SIGUSR2, SIG_IGN)
        toggleSource = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        toggleSource?.setEventHandler { pressed(); released() }
        toggleSource?.resume()

        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) {
                ToggleHotkey.pressed()
            } else {
                ToggleHotkey.released()
            }
            return noErr
        }, events.count, &events, nil, nil)

        // Logged so a launch nobody asked for can be matched to the key events and screen lock state around it.
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil,
                                                                queue: .main) { _ in trace(name) }
        }
        // A recorder that stopped by itself (silence, menu bar click) is only transcribing: the next press starts a
        // new recording instead of signalling it, which it would ignore.
        DistributedNotificationCenter.default().addObserver(forName: Config.finishingNotification, object: nil,
                                                            queue: .main) { note in
            guard let pid = (note.object as? String).flatMap({ pid_t($0) }) else { return }
            trace("finishing pid=\(pid)")
            signalled.insert(pid)
        }

        let id = EventHotKeyID(signature: OSType(0x56414754), id: 1) // 'VAGT'
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr { launchStandby() }
        return status == noErr
    }

    private static func launchStandby() {
        guard standby == nil, standbyLaunchedAt == nil else { return }
        standbyLaunchedAt = Date()
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = false
        config.arguments = ["standby", String(getpid())]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { app, error in
            DispatchQueue.main.async {
                trace("standby pid=\(app?.processIdentifier ?? 0) error=\(error?.localizedDescription ?? "none")")
                standbyLaunchedAt = nil
                standby = app
            }
        }
    }

    // The next standby is launched once this press's recorder has had its start to itself.
    private static func replaceStandby() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { launchStandby() }
    }

    private static func pressed() {
        pressedAt = Date()
        trace("pressed launching=\(launching) recorders=\(runningRecorderPIDs())")
        if launching {
            startedOnPress = false
            pendingSignal = SIGINT
            return
        }
        if let recorder = runningRecorder() {
            startedOnPress = false
            deliver(SIGINT, to: recorder)
            return
        }
        startedOnPress = true
        pendingSignal = nil
        defer { replaceStandby() }
        if let ready = standby, !ready.isTerminated, ready.isFinishedLaunching { // its signal handlers are up
            standby = nil
            trace("wake pid=\(ready.processIdentifier)")
            kill(ready.processIdentifier, SIGUSR2)
            return
        }
        if standby?.isTerminated == true { standby = nil }
        launching = true
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = false
        config.arguments = [TargetMode.vscode.rawValue]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { app, error in
            trace("launched pid=\(app?.processIdentifier ?? 0) error=\(error?.localizedDescription ?? "none")")
            DispatchQueue.main.async {
                launched = app?.processIdentifier
                awaitLaunch(app, until: Date().addingTimeInterval(5))
            }
        }
    }

    private static func released() {
        trace("released held=\(String(format: "%.2f", Date().timeIntervalSince(pressedAt)))s")
        guard startedOnPress, Date().timeIntervalSince(pressedAt) >= holdThreshold else { return }
        if launching {
            pendingSignal = SIGUSR1
        } else if let recorder = runningRecorder() {
            deliver(SIGUSR1, to: recorder)
        }
    }

    private static func awaitLaunch(_ app: NSRunningApplication?, until deadline: Date) {
        guard let app, !app.isTerminated, Date() < deadline else {
            launching = false
            pendingSignal = nil
            return
        }
        guard app.isFinishedLaunching else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { awaitLaunch(app, until: deadline) }
            return
        }
        launching = false
        if let pending = pendingSignal {
            pendingSignal = nil
            deliver(pending, to: app)
        }
    }

    private static func deliver(_ sig: Int32, to recorder: NSRunningApplication) {
        trace("signal \(sig == SIGUSR1 ? "send" : "finish") -> pid=\(recorder.processIdentifier)")
        signalled.insert(recorder.processIdentifier)
        kill(recorder.processIdentifier, sig)
    }

    private static func runningRecorderPIDs() -> [pid_t] {
        recorders().map(\.processIdentifier)
    }

    // Every instance of this bundle but this listener and the standby, the one launching included (a recorder this
    // listener launched meanwhile still counts; one started otherwise in that ~0.5 s, by `open` or Shortcuts, does
    // not, so a press then wakes the standby instead of stopping it).
    private static func recorders() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").filter {
            app in
            guard app.processIdentifier != getpid(), app.processIdentifier != standby?.processIdentifier else {
                return false
            }
            guard let since = standbyLaunchedAt, app.processIdentifier != launched else { return true }
            return (app.launchDate ?? .distantPast) < since
        }
    }

    // stderr is the LaunchAgent's ~/Library/Logs/voice-agent-hotkey.log.
    private static func trace(_ message: String) {
        let now = ISO8601DateFormatter.string(from: Date(), timeZone: .gmt,
                                              formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        fputs("\(now) \(message)\n", stderr) // ms: matched against a recorder's "live" steps
    }

    // A recorder already told to finish is skipped, so a press during its transcription starts a new recording.
    private static func runningRecorder() -> NSRunningApplication? {
        let recorders = recorders()
        signalled.formIntersection(recorders.map(\.processIdentifier))
        return recorders.first { !signalled.contains($0.processIdentifier) }
    }
}
