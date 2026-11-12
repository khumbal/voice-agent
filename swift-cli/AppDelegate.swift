import Cocoa
import Carbon.HIToolbox
import Speech
import AVFoundation
import CoreAudio
import NaturalLanguage

enum TargetMode: String {
    case vscode = "vscode"
    case tmux = "tmux"
    case listen = "listen" // `listen <id>`: typed nowhere, the text goes to results/<id>.json (see report)
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let speechRecognizer: SFSpeechRecognizer?

    private var silenceTimer: Timer?
    private var latestTranscript: String = ""
    private var committedTranscript = "" // text from before the recognizer's last restart (it restarts at pauses)
    private var currentSegment = "" // the recognizer's text since its last restart
    private var recognitionGeneration = 0
    private var startChanges: [String] = [] // logged: how each change of the recognizer's start was read
    private var gateProblemLogged = false // once per recording: why there is no speaker gate
    private var gateSilenced = false // on whisperQueue: a run of this recording had another voice silenced
    // Each window of heard16k scored so far, by its first frame: taken as it is heard (under tapLock: a copy of it to
    // gateQueue), so a run finds most of its windows done. gateQueue: one extractor call at a time.
    private var gateScores: [Int: Float?] = [:] // under gateLock
    private let gateLock = NSLock()
    private let gateQueue = DispatchQueue(label: "voice-agent.gate", qos: .userInitiated)
    private var nextGateWindow = 0 // under tapLock: the first frame of the next window to score while heard
    private var lockWaitTimedOut = false // on whisperQueue: a run waited Config.whisperTimeout for the Whisper lock
    private var whisperFile: AVAudioFile? // 16 kHz mono copy of the session for Whisper
    private static let whisperWAV: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                                                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                                    AVLinearPCMIsFloatKey: false]
    private var whisperConverter: AVAudioConverter?
    private var whisperURL = AppDelegate.newRecordingURL() // named again when a standby starts recording
    private static func newRecordingURL() -> URL {
        Config.recordingsDir.appendingPathComponent("\(Int(Date().timeIntervalSince1970)).wav")
    }
    // The run started at a pause (see Config.pauseSeconds). Under tapLock: the 16 kHz audio so far, the quiet since
    // the last loud buffer, and whether there was speech after the last pause's snapshot.
    private var heard16k: [Float] = []
    private var quietSeconds: TimeInterval = 0
    private var spokeSinceSnapshot = false
    private var snapshotFrames = 0 // heard16k.count at the last snapshot
    private var chunkStarts = [0] // where each chunk of heard16k starts (see Config.chunkSeconds); the last is open
    private var transcriptAtSnapshot: String? // main: Apple's text then
    private let whisperQueue = DispatchQueue(label: "voice-agent.whisper", qos: .userInitiated) // one run at a time
    // On whisperQueue: the last snapshot's run (on heard16k[start..<frames]), and each closed chunk's text in order
    // (nil: its run failed or was not needed, and the end decodes it again).
    private var snapshotText: (start: Int, frames: Int, text: String?)?
    private var chunkTexts: [String?] = []
    // Under processLock, not tapLock, so a run starting on whisperQueue does not hold up the audio tap (which takes it
    // only to drop a run). A snapshot's run starts only while its generation is current; speech after the snapshot
    // moves it on and stops the run.
    private let processLock = NSLock()
    private var snapshotGeneration = 0
    // A closed chunk's run is never stale, so speech does not stop it: only Esc, or the end once it will not use it
    // (runs on chunks from endStart on are not wanted).
    private var runningChunk: Int? // the chunk start of the run under way, when it is a closed chunk's
    private var endStart: Int?
    private var pauseRuns = 0 // logged: pause runs started, to see their cost
    private let pauseWAV = FileManager.default.temporaryDirectory
        .appendingPathComponent("voice-agent-\(getpid())-pause.wav")
    private let targetMode: TargetMode
    private let resultID: String? // `listen <id>`
    private var result = TranscriptResult() // filled as the recording ends, handed on by report
    private var isReported = false
    // Where the text goes in vscode mode: the app that had focus when the hotkey was pressed (this recorder opens
    // without taking it). VS Code gets it in its terminal through the extension; any other app at its cursor.
    private var targetApp = NSWorkspace.shared.frontmostApplication // a standby's is read again at the press
    // In VS Code, the window and the place in it (terminal tab, editor cursor) that had the keyboard then, as that
    // window's extension remembered it: set before vscodeSnapshotDone is left, nil when no window took the snapshot.
    private var vscodeSnapshot: (window: String, id: String)?
    // The folder of that place, after a tab in the snapshot's ack ("terminal Claude\t/path"): whose work file's
    // corrections the text gets. nil when the extension could not tell (no shell integration, an untitled file).
    private var vscodeFolder: String?
    private let vscodeSnapshotDone = DispatchGroup()
    private var isFinishing = false
    private var isDispatched = false // the text has left: Esc can no longer cancel
    private let tapLock = NSLock() // the audio tap thread reads recognitionRequest/whisperFile; main replaces them
    private var peakLevel: Float = 0 // loudest sample so far, under tapLock
    private var micLive = false // the input has delivered sound: main thread
    // Logged once the mic is live: ms to each step from this process's exec (a standby's: from its wake-up), where
    // the wait for the beep goes.
    private var startSteps: [String] = []
    private var firstBufferAt: Date? // under tapLock
    private var stepsFrom: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }()
    private func step(_ name: String, at date: Date = Date()) {
        startSteps.append("\(name)=\(Int(date.timeIntervalSince(stepsFrom) * 1000))")
    }
    private var recordingStarted = Date()
    private var recordedSeconds: TimeInterval = 0 // set when listening stops
    private var whisperStop: (() -> Void)? // under processLock: stops the run under way (a pause's, or for Esc)
    private var whisperCancelled = false // under processLock
    private var warming = false // under processLock: the warm-up is wanted or under way (see warmWhisperServer)
    private var warm = "skipped" // on whisperQueue: how the warm-up went, logged (done, stopped, skipped)
    private var cancelKeys: [EventHotKeyRef] = []
    private var microphone: Microphone? // what this recording listens to: set as it starts

    private var hudWindow: HUDWindow?
    private var statusItem: NSStatusItem?
    private var sigintSource: DispatchSourceSignal?
    private var sigtermSource: DispatchSourceSignal?
    private var sigusr1Source: DispatchSourceSignal?
    private var sigusr2Source: DispatchSourceSignal?
    private var sighupSource: DispatchSourceSignal?

    // A standby is launched ahead of the press by the hotkey listener (its pid), so the press skips the app's launch:
    // it waits, off the microphone and off screen, for SIGUSR2 and only then starts like a fresh recorder.
    private let standbyFor: pid_t?
    private var isStandby: Bool
    private var listenerExit: DispatchSourceProcess?
    private var standbyActivity: NSObjectProtocol?
    private var didFinishLaunching = false
    private var tink: NSSound? // loaded ahead: afplay took up to 0.4 s to start, after the mic was already live

    init(mode: TargetMode, resultID: String? = nil, standbyFor listener: pid_t? = nil) {
        self.targetMode = mode
        self.resultID = resultID
        self.standbyFor = listener
        self.isStandby = listener != nil
        self.speechRecognizer = SFSpeechRecognizer(locale: Config.locale)
        super.init()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopWhisperServer()
        // A snapshot still under way (a tap released at once, Esc) borrows the clipboard: stay until it is put back.
        hudWindow?.orderOut(nil)
        let deadline = Date().addingTimeInterval(Config.ackTimeout + 1)
        while vscodeSnapshotDone.wait(timeout: .now()) == .timedOut, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        // The speaker model loads now, while a standby waits for the press, not in the first run's turn.
        DispatchQueue.global(qos: .utility).async { _ = SpeakerGate.shared }
        // Not a standby, or one woken before it finished launching (its signal handlers were already up).
        guard let listener = standbyFor, isStandby else {
            begin()
            return loadTink()
        }
        loadTink()
        // The listener gone (install.sh restarts it for a new build), this standby would record with the old code.
        listenerExit = DispatchSource.makeProcessSource(identifier: listener, eventMask: .exit, queue: .main)
        listenerExit?.setEventHandler { NSApp.terminate(nil) }
        listenerExit?.resume()
        guard kill(listener, 0) == 0 else { return NSApp.terminate(nil) } // gone before the source was armed
        // Hidden and idle, it is an App Nap candidate: napping would delay its wake-up at the press.
        standbyActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Waits for the hotkey")
        hudWindow = HUDWindow() // built ahead, shown at the press
        _ = audioEngine.inputNode // made ahead too (no audio flows until the press starts the engine)
        SFSpeechRecognizer.requestAuthorization { _ in } // a first-time prompt comes now, not at the press
    }

    private func loadTink() {
        tink = NSSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: false)
        tink?.volume = 0.7
    }

    // SIGUSR2: the hotkey was pressed for this standby. What a fresh recorder reads at launch is read now.
    private func wake() {
        guard isStandby else { return }
        isStandby = false
        listenerExit?.cancel()
        stepsFrom = Date()
        targetApp = Self.focusedApp()
        whisperURL = Self.newRecordingURL()
        if didFinishLaunching { begin() } // else applicationDidFinishLaunching begins
    }

    // A long-running process's frontmostApplication follows activation notifications it has not handled yet when the
    // user switches apps and presses at once. Accessibility names the app with keyboard focus now, taken only when it
    // is a regular app: Spotlight or a menu bar extra has focus while the app in front stays the one to type into.
    // A hung focused app costs the press at most 0.25 s (not the default 6 s), then frontmostApplication is used.
    private static func focusedApp() -> NSRunningApplication? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        var pid: pid_t = 0
        guard AXIsProcessTrusted(),
              AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID(),
              AXUIElementGetPid(element as! AXUIElement, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular
        else { return NSWorkspace.shared.frontmostApplication }
        return app
    }

    // The microphone starts before the menu bar item and Esc, which nothing needs until it listens.
    private func begin() {
        // A start after a hotkey "wake" line was a standby's; with neither "wake" nor "launched", a direct
        // `open --args vscode|tmux` or Shortcuts.
        log("start pid=\(getpid())")
        step("launched") // a standby: from its wake-up, so about 0
        stopSpeaking()
        if let resultID { // the launching program cancels with SIGHUP to this pid (main.swift made the directory)
            try? String(getpid()).write(toFile: "\(Config.resultsDir)/\(resultID).pid", atomically: true,
                                        encoding: .utf8)
        }
        requestVSCodeSnapshot()
        setupFloatingHUD()
        step("hud")
        let start = { (status: SFSpeechRecognizerAuthorizationStatus) in
            self.step("auth")
            status == .authorized ? self.startRecording() : self.abort("ไม่ได้รับสิทธิ์ Speech Recognition")
        }
        if SFSpeechRecognizer.authorizationStatus() == .authorized {
            start(.authorized)
        } else {
            SFSpeechRecognizer.requestAuthorization { status in DispatchQueue.main.async { start(status) } }
        }
        setupMenuBar()
        setupCancelKey()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.title = "🔴 REC"
            button.target = self
            button.action = #selector(stopClicked)
            button.toolTip = "คลิกเพื่อหยุดฟังและพิมพ์ลง Terminal (ไม่กด Enter)"
        }
    }

    private func setupFloatingHUD() {
        if hudWindow == nil { hudWindow = HUDWindow() }
        hudWindow?.present()
    }

    @objc private func stopClicked() {
        finishAndDispatch()
    }

    func setupSignalHandlers() {
        // A dispatch source does not replace a signal's default action (terminate): ignore each one it handles.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGUSR1, SIG_IGN)
        signal(SIGUSR2, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN) // a hook that exits without reading its stdin

        sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource?.setEventHandler { [weak self] in self?.finish() }
        sigintSource?.resume()

        sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource?.setEventHandler { [weak self] in self?.finish() }
        sigtermSource?.resume()

        // SIGUSR1 = the push-to-talk key was released: finish and press Enter. Every other ending only types the text.
        sigusr1Source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        sigusr1Source?.setEventHandler { [weak self] in self?.finish(send: true) }
        sigusr1Source?.resume()

        sigusr2Source = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        sigusr2Source?.setEventHandler { [weak self] in self?.wake() }
        sigusr2Source?.resume()

        // SIGHUP = the program that launched `listen <id>` gave up waiting: cancel, as Esc does.
        sighupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        sighupSource?.setEventHandler { [weak self] in self?.isStandby == true ? NSApp.terminate(nil) : self?.cancel() }
        sighupSource?.resume()
    }

    // A standby has nothing to finish: told to stop, it just goes.
    private func finish(send: Bool = false) {
        isStandby ? NSApp.terminate(nil) : finishAndDispatch(send: send)
    }

    // Esc cancels without sending. It is registered only while this recording instance runs, so other apps get Esc
    // back as soon as it exits; Control-Option-Esc covers pressing it while still holding the push-to-talk keys.
    private func setupCancelKey() {
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            (NSApp.delegate as? AppDelegate)?.cancel()
            return noErr
        }, 1, &pressed, nil, nil)

        // A recording started while an earlier one is still transcribing owns Esc: the earlier one hands it over (a
        // hotkey another process holds cannot be registered), so Esc cancels what is being recorded.
        DistributedNotificationCenter.default().addObserver(forName: Config.startedNotification, object: nil,
                                                            queue: .main) { [weak self] note in
            guard let self, self.isFinishing, note.object as? String != String(getpid()) else { return }
            self.releaseCancelKeys()
        }
        DistributedNotificationCenter.default().postNotificationName(Config.startedNotification,
                                                                     object: String(getpid()), deliverImmediately: true)
        registerCancelKeys(attempts: 20)
    }

    // Once the text has left Esc cancels nothing: give it back to the other apps.
    private func releaseCancelKeys() {
        cancelKeys.forEach { UnregisterEventHotKey($0) }
        cancelKeys = []
    }

    private func postFinishing() {
        DistributedNotificationCenter.default().postNotificationName(Config.finishingNotification,
                                                                     object: String(getpid()), deliverImmediately: true)
    }

    private func registerCancelKeys(attempts: Int) {
        guard !isDispatched else { return } // a retry after the text left would take Esc back from the other apps
        for modifiers in [0, controlKey | optionKey] {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(kVK_Escape), UInt32(modifiers),
                                             EventHotKeyID(signature: OSType(0x56414754), id: 2),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { cancelKeys.append(ref) }
        }
        guard cancelKeys.count < 2, attempts > 1, !isFinishing else { return }
        cancelKeys.forEach { UnregisterEventHotKey($0) }
        cancelKeys = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.registerCancelKeys(attempts: attempts - 1) }
    }

    // Also works while Whisper is still transcribing: nothing is sent until dispatch.
    func cancel() {
        guard !isDispatched else { return }
        isDispatched = true
        isFinishing = true
        stopListening()
        closeWhisperFile()
        stopWhisper()
        try? FileManager.default.removeItem(at: whisperURL)
        // Nothing said yet: just go away. Cancelling what was said confirms the text is discarded.
        report(.cancelled)
        if !latestTranscript.isEmpty { playSound("Basso", wait: true) }
        NSApp.terminate(nil)
    }

    // No more Whisper runs, and no server. A run under way (a pause's) is stopped: whisper-cli would outlive this
    // process, and its WAV, removed when the run returns, this exit.
    private func stopWhisper() {
        processLock.lock()
        whisperCancelled = true
        whisperStop?()
        processLock.unlock()
        stopWhisperServer()
        try? FileManager.default.removeItem(at: pauseWAV)
    }

    private func stopListening() {
        silenceTimer?.invalidate()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
    }

    // One hit each: "Pop" plays two pops in a row and sounded like a double send.
    private func playSound(_ name: String, wait: Bool = false) {
        let path = "/System/Library/Sounds/\(name).aiff"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        task.arguments = ["-v", "0.7", path]
        try? task.run()
        if wait { task.waitUntilExit() }
    }

    // Nothing can be recorded: say why on the HUD (the log keeps it too), then go.
    private func abort(_ reason: String) {
        log("abort pid=\(getpid()) reason=\"\(reason)\" input=\"\(inputDeviceName)\"")
        report(.failed, error: reason)
        if !isFinishing { postFinishing() }
        isFinishing = true
        isDispatched = true
        releaseCancelKeys()
        stopListening()
        closeWhisperFile()
        stopWhisper()
        try? FileManager.default.removeItem(at: whisperURL)
        hudWindow?.showResult("", status: reason, state: .failed)
        playSound("Basso")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { NSApp.terminate(nil) }
    }

    private var inputDeviceName: String { microphone?.name ?? "none" }

    private func startRecording() {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            abort("ระบบถอดเสียงของ Apple ใช้งานไม่ได้ตอนนี้")
            return
        }

        let inputNode = audioEngine.inputNode
        // Before the format is read: it is the device's. Not pinned, the engine records from the default.
        let microphones = Microphone.all()
        let chosen = Microphone.chosen(from: microphones, preferred: Config.preferredMicrophones)
        var pinned = false
        if var id = chosen?.id, let unit = inputNode.audioUnit {
            pinned = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
        }
        microphone = pinned ? chosen : microphones.first(where: \.isDefault)
        step("mic")
        // The device's own format: the output side keeps the default's rate after pinning (a 44.1 kHz headset with
        // the built-in at 48 kHz: a 48 kHz tap that never gets a buffer).
        let recordingFormat = inputNode.inputFormat(forBus: 0)
        log("mic pid=\(getpid()) input=\"\(inputDeviceName)\" rate=\(Int(recordingFormat.sampleRate)) "
            + "default=\"\(microphones.first(where: \.isDefault)?.name ?? "none")\" "
            + "present=\"\(microphones.map(\.name).joined(separator: ", "))\"")
        // No input device: installing a tap with this format raises an exception that kills the app without a trace.
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            abort("ไม่พบไมโครโฟน")
            return
        }

        if let whisperFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1,
                                             interleaved: false) {
            try? FileManager.default.createDirectory(at: Config.recordingsDir, withIntermediateDirectories: true)
            whisperFile = try? AVAudioFile(forWriting: whisperURL, settings: Self.whisperWAV,
                                           commonFormat: .pcmFormatFloat32, interleaved: false)
            whisperConverter = AVAudioConverter(from: recordingFormat, to: whisperFormat)
            // Mixed, not channel 0 only: a stereo input with the mic on one side. A discrete or unknown channel
            // layout (any count) converted to silence in a probe, mixed or not, even on channel 0: name another
            // microphone for it.
            whisperConverter?.downmix = true
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            let peak = Self.peak(of: buffer)
            self.tapLock.lock()
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }
            if self.peakLevel < Config.silentInputPeak, peak >= Config.silentInputPeak {
                DispatchQueue.main.async { self.micBecameLive() }
            }
            self.peakLevel = max(self.peakLevel, peak)
            self.recognitionRequest?.append(buffer)
            self.writeForWhisper(buffer, peak: peak)
            self.tapLock.unlock()
            self.hudWindow?.showLevel(peak: peak)
        }
        // The input device changed (the default one, when nothing was pinned: AirPods connected or gone): the engine
        // stops and the tap would only hear silence, so finish with what was heard. Pinned to a device (the built-in,
        // one at another rate than the default), the engine also reports a change 2-40 ms after it starts while it
        // keeps running and the tap keeps hearing: that one is only logged. A pinned device unplugged was not
        // measured; if the engine keeps running, the silence timer ends the take (held to talk: the release does),
        // or micWakeTimeout aborts it before the mic was live.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audioEngine,
                                               queue: .main) { [weak self] _ in
            guard let self, !self.isFinishing else { return }
            let running = self.audioEngine.isRunning
            self.log("input changed pid=\(getpid()) input=\"\(self.inputDeviceName)\" running=\(running)")
            guard !running else { return }
            self.finishAndDispatch()
        }

        audioEngine.prepare()
        step("prepared")
        do {
            try audioEngine.start()
            recordingStarted = Date()
            step("engine", at: recordingStarted)
            hudWindow?.showStatus("รอไมค์พร้อม… (เริ่มพูดเมื่อได้ยินเสียงติ๊ง)", state: .waiting)
            DispatchQueue.main.asyncAfter(deadline: .now() + Config.micWakeTimeout) { [weak self] in
                guard let self, !self.micLive, !self.isFinishing else { return }
                // A microphone with a noise gate stays silent until someone speaks: say so too.
                self.abort("ไมค์ไม่มีเสียงเข้ามา (\(self.inputDeviceName)) — ดูปุ่ม mute หรือเลือกไมค์ใน "
                           + "~/.config/voice-agent/microphones.txt "
                           + "(ไมค์ที่มี noise gate: พูดได้เลยไม่ต้องรอเสียงติ๊ง)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Config.maxRecording) { [weak self] in
                self?.finishAndDispatch()
            }
        } catch {
            abort("เปิดไมโครโฟนไม่ได้ (\(error.localizedDescription))")
            return
        }
        startWhisperServer()

        startRecognitionTask(recognizer)
    }

    // The recognizer finalises (or errors with "no speech") at every pause and then stops listening. The session must
    // not end there: keep the text heard so far and start a fresh task; silence, release or Esc end the session.
    private func startRecognitionTask(_ recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.contextualStrings = Config.contextualStrings
        tapLock.lock()
        recognitionRequest = request
        tapLock.unlock()
        currentSegment = ""

        recognitionGeneration += 1
        let generation = recognitionGeneration
        let taskStarted = Date()
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, !self.isFinishing, generation == self.recognitionGeneration else { return }

                if let result {
                    let segment = result.bestTranscription.formattedString
                    let current = self.currentSegment
                    // A restart keeps what the recognizer had (the pause becomes a space); a revision replaces it.
                    if let change = Transcript.startChange(from: current, to: segment) {
                        if change == "restart" {
                            self.committedTranscript = self.joined(self.committedTranscript, current)
                        }
                        self.startChanges.append("\(change): \(current) -> \(segment)")
                    }
                    self.currentSegment = segment
                    let heard = self.joined(self.committedTranscript, segment)
                    // Only new words mean the speaker is still talking. The final result comes from the recognizer's
                    // own pause detection (~2 s after the last word) and repeats or reformats the text: restarting
                    // the wait there doubled it (4.8 s of trailing silence in tap recordings for a 2.5 s timeout).
                    if heard != self.latestTranscript, !result.isFinal { self.resetSilenceTimer() }
                    self.latestTranscript = heard
                    self.hudWindow?.updateTranscript(self.latestTranscript)
                    if result.isFinal {
                        self.committedTranscript = self.latestTranscript
                        self.startRecognitionTask(recognizer)
                    }
                } else if let error = error as NSError? {
                    // Before the microphone delivers sound "no speech" says nothing about the speaker: keep waiting
                    // (micWakeTimeout ends a wait that never ends).
                    if self.latestTranscript.isEmpty && self.micLive
                        && !NSEvent.modifierFlags.isSuperset(of: [.control, .option]) {
                        // "No speech" is the usual one; anything else (dictation restricted, model missing) is kept.
                        self.log("recognizer error pid=\(getpid()) \(error.domain) \(error.code)")
                        self.finishAndDispatch() // nothing heard: ends quietly unless the microphone was silent
                    } else if !self.micLive {
                        // An error that comes back at once (dictation restricted, model missing) would otherwise
                        // restart in a tight loop until micWakeTimeout; any other ("no speech") restarts at once, as
                        // audio sent to the ended request is lost.
                        self.log("recognizer error before live pid=\(getpid()) \(error.domain) \(error.code)")
                        self.committedTranscript = self.latestTranscript
                        let delay = Date().timeIntervalSince(taskStarted) < 1 ? 0.3 : 0
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            guard !self.isFinishing, generation == self.recognitionGeneration else { return }
                            self.startRecognitionTask(recognizer)
                        }
                    } else {
                        self.committedTranscript = self.latestTranscript
                        self.startRecognitionTask(recognizer)
                    }
                }
            }
        }
    }

    private func joined(_ parts: String...) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    // The beep means "speak now": it waits until the microphone actually delivers sound, which a USB microphone
    // waking up or a muted one may not do for seconds; words said before it would be lost.
    private func micBecameLive() {
        guard !micLive, !isFinishing else { return }
        micLive = true
        if let tink { tink.play() } else { playSound("Tink") }
        tapLock.lock()
        if let first = firstBufferAt { step("buffer", at: first) }
        tapLock.unlock()
        step("live")
        let from = ISO8601DateFormatter.string(from: stepsFrom, timeZone: .gmt,
                                               formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        log("live pid=\(getpid()) standby=\(standbyFor != nil) from=\(from) ms: \(startSteps.joined(separator: " "))")
        hudWindow?.showStatus("กำลังฟัง · \(inputDeviceName)", state: .listening)
        resetSilenceTimer() // a tap with no speech ends too, even if the recognizer never reports
    }

    // Over every channel: an interface may have the mic in any input.
    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 1 } // not float: cannot tell, assume sound
        var peak: Float = 0
        for channel in 0..<(buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)) {
            for i in 0..<Int(buffer.frameLength) * buffer.stride { peak = max(peak, abs(channels[channel][i])) }
        }
        return peak
    }

    // Under tapLock.
    private func writeForWhisper(_ buffer: AVAudioPCMBuffer, peak: Float) {
        guard let file = whisperFile, let converter = whisperConverter else { return }
        let ratio = file.processingFormat.sampleRate / buffer.format.sampleRate
        guard let converted = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                               frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1)
        else { return }
        var consumed = false
        converter.convert(to: converted, error: nil) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        try? file.write(from: converted)

        if let samples = converted.floatChannelData?[0] {
            heard16k.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(converted.frameLength)))
        }
        while heard16k.count >= nextGateWindow + Config.speakerWindow {
            // A copy: a slice would keep heard16k shared, so the next append would copy all of it.
            let start = nextGateWindow, window = Array(heard16k[start..<start + Config.speakerWindow])
            nextGateWindow += Config.speakerHop
            gateQueue.async {
                guard let gate = self.gate() else { return }
                let score = gate.score(window[...])
                self.gateLock.lock()
                self.gateScores[start] = score
                self.gateLock.unlock()
            }
        }
        if peak >= peakLevel * Config.pauseQuietRatio {
            quietSeconds = 0
            if !spokeSinceSnapshot {
                spokeSinceSnapshot = true
                dropSnapshotRun() // the last snapshot misses this speech
            }
        } else {
            quietSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
            if spokeSinceSnapshot, quietSeconds >= Config.pauseSeconds { takeSnapshot() }
        }
    }

    // The last snapshot's run is not the one the end needs: it does not start, or stops (any run under way before the
    // end's own is a pause's).
    private func dropSnapshotRun() {
        processLock.lock()
        snapshotGeneration += 1
        if runningChunk == nil, !warming { whisperStop?() }
        processLock.unlock()
    }

    // Under processLock: a warm-up still under way yields to the real run queued behind it.
    private func stopWarmUp() {
        guard warming else { return }
        warming = false
        whisperStop?()
    }

    // Under tapLock: Whisper on what was heard so far, at whisperQueue's next turn. Once the open chunk is long
    // enough, this pause closes it and the run is its text.
    private func takeSnapshot() {
        spokeSinceSnapshot = false
        let frames = heard16k.count, open = chunkStarts[chunkStarts.count - 1]
        snapshotFrames = frames
        let closes = Double(frames - open) >= Config.chunkSeconds * 16000
        let start = closes ? open : Transcript.runStart(upTo: frames, chunkStarts: chunkStarts)
        if closes { chunkStarts.append(frames) }
        let samples = Array(heard16k[start..<frames]) // not heard16k itself: the tap's next append would copy it all
        processLock.lock()
        let generation = snapshotGeneration
        stopWarmUp()
        processLock.unlock()
        DispatchQueue.main.async { self.transcriptAtSnapshot = self.latestTranscript }
        whisperQueue.async {
            self.processLock.lock()
            let current = generation == self.snapshotGeneration
            if closes { self.runningChunk = start }
            self.processLock.unlock()
            guard closes || current else { return } // spoken over while waiting its turn
            let seconds = Double(samples.count) / 16000
            let text = Self.writeWAV(self.gated(samples, from: start) ?? samples, to: self.pauseWAV)
                ? self.transcribeWithWhisper(self.pauseWAV, seconds: seconds, generation: closes ? nil : generation,
                                             chunk: closes ? start : nil)
                : nil
            try? FileManager.default.removeItem(at: self.pauseWAV)
            if closes {
                self.processLock.lock()
                self.runningChunk = nil
                self.processLock.unlock()
                self.chunkTexts.append(text)
            }
            self.snapshotText = (start, frames, text)
        }
    }

    // On gateQueue: the speaker gate, when it gates this recording's microphone (set as the recording starts, before
    // any audio); else nil, logged once.
    private func gate() -> SpeakerGate? {
        guard let gate = SpeakerGate.shared, gate.hears(inputDeviceName) else {
            let why = SpeakerGate.shared.map { "enrolled on \"\($0.microphone)\", not \"\(inputDeviceName)\"" }
            if !gateProblemLogged { log("gate off pid=\(getpid()) \(why ?? SpeakerGate.problem)") }
            gateProblemLogged = true
            return nil
        }
        return gate
    }

    // On whisperQueue: the run with the parts only other voices fill silenced (nil: nothing to silence, or no gate),
    // and a log line of its window scores for tuning Config.speakerThreshold.
    private func gated(_ samples: [Float], from start: Int) -> [Float]? {
        let started = Date()
        let gated = gateQueue.sync { () -> (kept: [Float]?, scores: [Float?], silenced: [Range<Int>])? in
            guard let gate = gate() else { return nil }
            gateLock.lock()
            let known = gateScores
            gateLock.unlock()
            return gate.gate(samples, known: known, offset: start)
        }
        guard let result = gated else { return nil }
        gateLock.lock()
        for (window, score) in zip(Config.speakerWindows(count: samples.count, offset: start), result.scores) {
            gateScores[start + window] = score
        }
        gateLock.unlock()
        let seconds = { (frames: Int) in String(format: "%.1f", Double(frames) / 16000) }
        let silenced = result.silenced.map { seconds($0.lowerBound) + "-" + seconds($0.upperBound) }
        log("gate pid=\(getpid()) at=\(seconds(start)) seconds=\(seconds(samples.count)) "
            + "ms=\(Int(Date().timeIntervalSince(started) * 1000)) "
            + "scores=\"\(Self.scoreList(result.scores))\" silenced=\"\(silenced.joined(separator: " "))\"")
        if !silenced.isEmpty { gateSilenced = true }
        return result.kept
    }

    static func scoreList(_ scores: [Float?]) -> String {
        scores.map { $0.map { String(format: "%.2f", $0) } ?? "-" }.joined(separator: " ")
    }

    // On whisperQueue: the end's run, on heard[start...]. From the start, with nothing silenced, that is the
    // recording's own file (kept as recorded).
    private func transcribeEnd(_ heard: [Float], from start: Int) -> String? {
        let kept = gated(Array(heard[start...]), from: start)
        guard start > 0 || kept != nil else { return transcribeWithWhisper(whisperURL, seconds: recordedSeconds) }
        defer { try? FileManager.default.removeItem(at: pauseWAV) }
        let samples = kept ?? Array(heard[start...])
        return Self.writeWAV(samples, to: pauseWAV)
            ? transcribeWithWhisper(pauseWAV, seconds: Double(samples.count) / 16000) : nil
    }

    // A 16 kHz WAV for whisper-cli, closed (its header written) on return.
    static func writeWAV(_ samples: [Float], to url: URL) -> Bool {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0],
              let file = try? AVAudioFile(forWriting: url, settings: whisperWAV, commonFormat: .pcmFormatFloat32,
                                          interleaved: false)
        else { return false }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return (try? file.write(from: buffer)) != nil
    }

    // The decoding both whisper-cli and whisper-server get.
    // Greedy decoding (-bs 1 -bo 1) was as accurate as the default beam search here, and faster.
    // -sns: no "[BLANK_AUDIO]" or "(music)" tags, which would pass for English words in the merge.
    // VAD drops the silence (e.g. still holding the key after speaking) that Whisper tends to fill with text;
    // the 200 ms pad keeps the first syllable when speech starts right at the beep.
    private static var whisperArguments: [String] {
        ["-m", Config.whisperModel, "-l", "th", "-nt", "-sns", "-bs", "1", "-bo", "1"]
            + (FileManager.default.fileExists(atPath: Config.whisperVADModel)
                ? ["--vad", "-vm", Config.whisperVADModel, "-vp", "200"] : [])
    }

    // nil means "use Apple's text" (no whisper, failure, cancelled, or a pause's run that speech made stale), "" that
    // it heard nothing. On this recording's whisper-server when it is up, else whisper-cli. `chunk`: the start of the
    // closed chunk this run is the text of.
    private func transcribeWithWhisper(_ wav: URL, seconds: TimeInterval, generation: Int? = nil,
                                       chunk: Int? = nil) -> String? {
        guard let cli = Config.whisperCLI.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              FileManager.default.fileExists(atPath: Config.whisperModel) else { return nil }
        // Waits for another recording's run (or the learner's replay), but no longer than a run may take: past that
        // Apple's text is used, as for a slow run.
        // Under processLock: not cancelled, nor a pause's run that speech made stale (which, waiting here, would hold
        // up the end's run behind it), nor a chunk's the end decodes again.
        func wanted() -> Bool {
            !whisperCancelled && generation.map { $0 == snapshotGeneration } ?? true
                && chunk.map { $0 < endStart ?? Int.max } ?? true
        }
        let lock = open(Config.whisperLockPath, O_CREAT | O_RDWR, 0o600)
        defer { if lock >= 0 { close(lock) } }
        // Once a run waited that long, the holder is a long job (a replay held it through a 36 s dictation: three runs
        // waited 10 s each, 29 s to a text without Whisper's), so later runs take the lock only if it is free.
        let lockDeadline = Date().addingTimeInterval(lockWaitTimedOut ? 0 : Config.whisperTimeout)
        while lock >= 0, flock(lock, LOCK_EX | LOCK_NB) != 0 {
            processLock.lock()
            let waiting = wanted()
            processLock.unlock()
            guard waiting else { return nil }
            guard Date() < lockDeadline else {
                lockWaitTimedOut = true
                return nil
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let timeout = max(Config.whisperTimeout, seconds * Config.whisperTimeoutPerSecond)
        if case .done(let text) = transcribeOnServer(wav, timeout: timeout, isPause: generation != nil || chunk != nil,
                                                     wanted: wanted) {
            return text
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = Self.whisperArguments + ["-f", wav.path, "-np", "--prompt", Config.whisperPrompt]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        processLock.lock()
        let started = wanted() && (try? process.run()) != nil
        if started {
            whisperStop = { if process.isRunning { process.terminate() } }
            if generation != nil || chunk != nil { pauseRuns += 1 }
            cliRuns += 1
        }
        processLock.unlock()
        guard started else { return nil }
        defer {
            processLock.lock()
            whisperStop = nil
            processLock.unlock()
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return Self.joinedSegments(String(decoding: data, as: UTF8.self))
    }

    // Whisper prints one line per segment.
    private static func joinedSegments(_ output: String) -> String {
        output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // Started with the recording, so the model is loaded by the first pause (ready in 0.6 s measured): every run then
    // skips the ~0.5 s whisper-cli spends loading it (same text on the reference recordings). It lives only as long as
    // this recorder: stopped after the last run, and a guard shell kills it if this process dies without stopping it.
    // Its inference path is this recorder's own, so a request never reaches another recorder's server that took the
    // port first. Under processLock.
    private var whisperServer: (process: Process, guardInput: Pipe, url: URL, started: Date)?
    private var serverRuns = 0 // logged with cliRuns: which one did the work
    private var cliRuns = 0

    private func startWhisperServer() {
        guard let binary = Config.whisperServer.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              FileManager.default.fileExists(atPath: Config.whisperModel), let port = Self.freePort(),
              let url = URL(string: "http://127.0.0.1:\(port)/inference-\(Self.newAckID())") else { return }
        let server = Process()
        server.executableURL = URL(fileURLWithPath: binary)
        server.arguments = Self.whisperArguments + ["--host", "127.0.0.1", "--port", String(port),
                                                    "--inference-path", url.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        guard (try? server.run()) != nil else { return }
        // Its stdin closes when this process exits, however it exits; then it stops the server.
        let guardShell = Process(), guardInput = Pipe()
        guardShell.executableURL = URL(fileURLWithPath: "/bin/sh")
        guardShell.arguments = ["-c", "read _; kill \(server.processIdentifier) 2>/dev/null"]
        guardShell.standardInput = guardInput
        guard (try? guardShell.run()) != nil else {
            server.terminate()
            return
        }
        processLock.lock()
        whisperServer = (server, guardInput, url, Date())
        processLock.unlock()
        warmWhisperServer()
    }

    private func stopWhisperServer() {
        processLock.lock()
        let server = whisperServer
        whisperServer = nil
        processLock.unlock()
        server?.process.terminate()
        try? server?.guardInput.fileHandleForWriting.close()
    }

    // The GPU clocks down when idle: after a minute without a run, the first one takes 1.7 s instead of 1.1 s (a
    // 2.7 s recording, measured twice). A second of faint noise, decoded without VAD (which would skip it: 0.01 s),
    // is that first run, as the recording starts: 1.2 s. Not digital silence: Whisper decoded that for 12.9 s,
    // so the warm-up ended only when stopped or at whisperTimeout, holding the GPU and the lock until then. Taking
    // the first snapshot, starting the end or Esc stops it while it is under way (stopWarmUp; the server drops it,
    // at no cost to the next run). Skipped when another process holds the Whisper lock: the GPU is busy, so warm.
    // The lock is held through this server's load (~0.6 s) too; another recorder's run waits that long for it.
    private func warmWhisperServer() {
        processLock.lock()
        warming = true
        processLock.unlock()
        whisperQueue.async {
            defer {
                self.processLock.lock()
                self.warming = false
                self.processLock.unlock()
            }
            self.processLock.lock()
            let wanted = self.warming && !self.whisperCancelled
            self.processLock.unlock()
            let lock = open(Config.whisperLockPath, O_CREAT | O_RDWR, 0o600)
            guard wanted, lock >= 0 else { return }
            defer { close(lock) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return }
            var state: UInt32 = 1 // the same noise each time (+-0.001), as measured
            let noise = (0..<16000).map { _ -> Float in
                state = state &* 1_664_525 &+ 1_013_904_223
                return (Float(state >> 16) / 65536 - 0.5) * 0.002
            }
            guard Self.writeWAV(noise, to: self.pauseWAV) else { return }
            defer { try? FileManager.default.removeItem(at: self.pauseWAV) }
            let run = self.transcribeOnServer(self.pauseWAV, timeout: Config.whisperTimeout, isPause: false,
                                              warmUp: true) { !self.whisperCancelled && self.warming }
            switch run {
            case .done(.some): self.warm = "done"
            case .done(nil): self.warm = "stopped"
            case .unavailable: break
            }
        }
    }

    // A port nothing listens on now; another process may take it before the server binds it, which the inference
    // path catches.
    private static func freePort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        return bound ? UInt16(bigEndian: address.sin_port) : nil
    }

    // done: the text as transcribeWithWhisper returns it (nil when cancelled, stale or too slow, as for whisper-cli).
    // unavailable: the server cannot do this run, whisper-cli does it.
    private enum ServerRun { case done(String?), unavailable }

    // Called with the Whisper lock held. A server still loading the model is waited for, as long as it runs.
    // warmUp: the run is warmWhisperServer's, decoded without VAD (which would skip its faint noise) and not counted.
    private func transcribeOnServer(_ wav: URL, timeout: TimeInterval, isPause: Bool, warmUp: Bool = false,
                                    wanted: () -> Bool) -> ServerRun {
        processLock.lock()
        let server = whisperServer
        processLock.unlock()
        guard let server, let audio = try? Data(contentsOf: wav) else { return .unavailable }
        let boundary = "voice-agent-\(Self.newAckID())"
        var body = Data()
        func part(_ name: String, _ value: Data, file: Bool = false) {
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"".utf8)
            body += Data((file ? "; filename=\"audio.wav\"\r\nContent-Type: audio/wav" : "").utf8)
            body += Data("\r\n\r\n".utf8) + value + Data("\r\n".utf8)
        }
        part("file", audio, file: true)
        part("prompt", Data(Config.whisperPrompt.utf8))
        part("response_format", Data("text".utf8))
        if warmUp { part("vad", Data("false".utf8)) }
        body += Data("--\(boundary)--\r\n".utf8)
        var request = URLRequest(url: server.url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let readyDeadline = server.started.addingTimeInterval(Config.whisperServerStartTimeout)
        var counted = false // a wait for the model is one run
        while true {
            var result: (data: Data?, response: URLResponse?, error: Error?) = (nil, nil, nil)
            let done = DispatchSemaphore(value: 0)
            processLock.lock()
            guard wanted() else {
                processLock.unlock()
                return .done(nil)
            }
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                result = (data, response, error)
                done.signal()
            }
            whisperStop = { task.cancel() } // the server drops a run whose connection closes
            task.resume()
            if !counted {
                counted = true
                if isPause { pauseRuns += 1 }
                if !warmUp { serverRuns += 1 }
            }
            processLock.unlock()
            done.wait()
            processLock.lock()
            whisperStop = nil
            processLock.unlock()

            if let response = result.response as? HTTPURLResponse, response.statusCode == 200, let data = result.data {
                return .done(Self.joinedSegments(String(decoding: data, as: UTF8.self)))
            }
            switch (result.error as? URLError)?.code {
            case .cancelled?, .timedOut?:
                return .done(nil) // as a stopped or slow whisper-cli: running it again would only take longer
            case .cannotConnectToHost? where server.process.isRunning && Date() < readyDeadline:
                Thread.sleep(forTimeInterval: 0.05) // still loading the model
            default:
                // Exited, wrong server on the port (404), or an error: whisper-cli from now on.
                stopWhisperServer()
                return .unavailable
            }
        }
    }

    private func pruneRecordings() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Config.recordingsDir,
                                                                  includingPropertiesForKeys: nil)) ?? []
        let recordings = files.filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        recordings.dropFirst(Config.recordingsKept).forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: Config.silenceTimeout, repeats: false) { [weak self] _ in
            // Push-to-talk: while the hotkey is still held, a pause is not the end — the release is.
            if NSEvent.modifierFlags.isSuperset(of: [.control, .option]) {
                self?.resetSilenceTimer()
                return
            }
            self?.finishAndDispatch()
        }
    }

    // Under the lock, so no tap write is still in flight when the WAV closes.
    private func closeWhisperFile() {
        tapLock.lock()
        whisperFile = nil
        tapLock.unlock()
    }

    // Letters and digits only: the recognizer's final result may respace or repunctuate what it heard.
    private static func spoken(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }

    private func finishAndDispatch(send: Bool = false) {
        guard !isFinishing else { return }
        isFinishing = true
        postFinishing()
        stopListening()
        closeWhisperFile()
        recordedSeconds = Date().timeIntervalSince(recordingStarted)
        tapLock.lock()
        let peak = peakLevel
        // The last pause's run stands for the whole recording when nothing was said after it: not loud enough to end
        // the pause, nor (for a quieter word) heard by Apple. Apple's text also changes when its last words come, or
        // are revised, after the snapshot (47 of 155 kept recordings; decoded again, all 47 gave the same text, ~0.8 s
        // later): with only silence recorded since, that is what the change is. Only on the enrolled microphone,
        // where silence was measured (see Config.isSilent).
        let snapshot = spokeSinceSnapshot || snapshotFrames == 0 ? nil : snapshotFrames
        let sameText = transcriptAtSnapshot.map(Self.spoken) == Self.spoken(latestTranscript)
        let silentEnd = snapshot != nil && !sameText && SpeakerGate.shared?.hears(inputDeviceName) == true
            && Config.isSilent(heard16k[snapshotFrames...]) // logged: the run was taken on the silence alone
        let reusable = snapshot != nil && (sameText || silentEnd)
        // The WAV is closed: nothing is appended any more, so this is all of it, shared without a copy. When the last
        // pause's run stands for the recording, the end's starts where that one did (not on the quiet after it).
        let heard = heard16k, starts = chunkStarts
        let start = Transcript.runStart(upTo: reusable ? snapshotFrames : heard.count, chunkStarts: starts)
        tapLock.unlock()
        if !reusable { // the run below must not wait for one it will not use
            dropSnapshotRun()
            processLock.lock()
            endStart = start // a chunk's run from there on would be decoded again below: stop it, or do not start it
            if let chunk = runningChunk, chunk >= start { whisperStop?() }
            stopWarmUp()
            processLock.unlock()
        }

        // Apple heard nothing: skip Whisper too, which tends to hallucinate a phrase on silence.
        let appleText = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appleText.isEmpty else {
            stopWhisper()
            // The start's steps too: a press that never went live shows which one took the time.
            log("empty pid=\(getpid()) send=\(send) seconds=\(Int(recordedSeconds)) peak=\(peak) "
                + "input=\"\(inputDeviceName)\" live=\(micLive) ms: \(startSteps.joined(separator: " "))")
            if peak < Config.silentInputPeak, recordedSeconds >= 1 {
                abort("ไมค์ไม่มีเสียงเข้ามา (\(inputDeviceName)) — ลองพูดใหม่ "
                      + "หรือเลือกไมค์ใน ~/.config/voice-agent/microphones.txt")
            } else {
                report(.empty)
                NSApp.terminate(nil) // nothing said: no error sound
            }
            return
        }

        hudWindow?.showResult(appleText, status: "กำลังถอดความ… (Esc ยกเลิก)", state: .transcribing)
        let started = Date()
        whisperQueue.async { // after the pause's run, if one is under way, and every closed chunk's
            let (from, chunks) = Transcript.endChunks(self.chunkTexts, chunkStarts: starts, runStart: start)
            let last = self.snapshotText
            let early = reusable && last?.frames == snapshot && last?.start == from ? last?.text : nil
            let tail = early ?? self.transcribeEnd(heard, from: from)
            let parts = chunks + (tail.map { [$0] } ?? [])
            let text = parts.isEmpty ? nil : parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let whisperText = text.flatMap { $0.isEmpty ? nil : Transcript.collapseRepeats($0) }
            let whisperInstalled = Config.whisperCLI.contains { FileManager.default.isExecutableFile(atPath: $0) }
                && FileManager.default.fileExists(atPath: Config.whisperModel)
            // The corrections depend on where the text goes: the snapshot is waited for here, not only at delivery
            // (a recording shorter than its ack). Without one, the shared corrections.
            _ = self.vscodeSnapshotDone.wait(timeout: .now() + Config.ackTimeout + 1)
            let folder = self.vscodeFolder
            // The log keeps the raw texts, so new mishearings can be added to the vocabulary.
            let final = Transcript.finalText(apple: appleText, whisper: whisperText, folder: folder)
            let finalText = final.text
            // Without Whisper installed Apple's text is all there is: sent as before.
            let (result, doubt) = Transcript.result(final: final, apple: appleText,
                                                    whisper: tail == nil ? nil : whisperText ?? "",
                                                    installed: whisperInstalled, send: send,
                                                    silenced: self.gateSilenced, folder: folder)
            self.pruneRecordings()
            self.log("file=\(self.whisperURL.lastPathComponent) send=\(send) engine=\(whisperText == nil ? "apple" : "merged") "
                + "whisper_ms=\(Int(Date().timeIntervalSince(started) * 1000)) apple=\"\(appleText)\" "
                + "whisper=\"\(whisperText ?? "")\" final=\"\(finalText)\" "
                + "starts=\"\(self.startChanges.joined(separator: " | "))\" "
                + "early=\(early != nil) silent_end=\(silentEnd) pause_runs=\(self.pauseRuns) "
                + "server_runs=\(self.serverRuns) "
                + "cli_runs=\(self.cliRuns) warm=\(self.warm) chunks=\(chunks.count) held=\"\(doubt ?? "")\" "
                + "project=\(folder.map(Config.projectName) ?? "-")")
            self.stopWhisperServer() // the last run is over: give its memory back before the text is delivered
            DispatchQueue.main.async { self.dispatch(finalText, send: send, doubt: doubt, result: result) }
        }
    }

    private func log(_ line: String) {
        let entry = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        let path = Config.logURL.path
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
           size > Config.logRotationBytes {
            try? FileManager.default.removeItem(atPath: path + ".1")
            try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
        }
        // O_APPEND: two recorders running at once (one still transcribing) never write over each other's lines.
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        _ = entry.utf8CString.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count - 1) }
        close(fd)
    }

    // doubt: why the text is typed without Return although the user held the key to send (see doubt(apple:...)).
    // result: what report hands on, taken only here on main, so a cancel while Whisper ran reports no text.
    private func dispatch(_ finalText: String, send: Bool, doubt: String?, result: TranscriptResult) {
        guard !isDispatched else { return } // cancelled while Whisper ran
        isDispatched = true
        self.result = result
        releaseCancelKeys()
        let isSafe = !Config.dangerousKeywords.contains { finalText.localizedCaseInsensitiveContains($0) }
        let execute = send && isSafe && doubt == nil

        let toCursor = targetMode == .vscode && targetApp.map { $0.bundleIdentifier != Config.vscodeBundleID } ?? false
        // Typing into another app needs the Accessibility permission, which a managed Mac may not allow (and asking
        // for it is logged there): without it the text waits on the clipboard for the user's ⌘V.
        let pasteByUser = toCursor && !AXIsProcessTrusted()
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            var place = toCursor ? "ที่ cursor" : "ใน Terminal"
            var entered = execute && !pasteByUser // Return was pressed after the text
            var ack = "-" // the extension's answer, logged
            switch self.targetMode {
            case .vscode where pasteByUser:
                break
            case .vscode where toCursor:
                failure = self.typeAtCursor(text: finalText, execute: execute)
            case .vscode:
                let outcome = self.deliverToVSCode(text: finalText, execute: execute)
                ack = outcome ?? "none"
                switch outcome {
                case nil:
                    failure = "VS Code ไม่ยืนยันว่าได้รับข้อความ"
                case "editor"?:
                    place = "ใน editor" // the editor never gets a Return
                    entered = false
                case "terminal"?:
                    entered = false // a terminal the extension had to open runs a plain shell
                case "terminal-run"?:
                    break
                case let outcome?:
                    failure = "VS Code: " + (outcome.hasPrefix("error ") ? String(outcome.dropFirst(6)) : outcome)
                }
            case .tmux:
                failure = self.sendToTmux(text: finalText, execute: execute)
            case .listen:
                place = "ให้โปรแกรมที่รอฟัง"
                entered = false
            }
            self.report(failure == nil ? .done : .failed, error: failure)
            self.log("dispatch pid=\(getpid()) target=\(self.targetApp?.bundleIdentifier ?? "none") ack=\"\(ack)\" "
                + "failure=\"\(failure ?? "")\" paste_by_user=\(pasteByUser) entered=\(entered)")
            DispatchQueue.main.async {
                let check = send ? doubt.map { " — \($0) ตรวจก่อนส่ง" } ?? "" : ""
                if let failure {
                    // Nothing typed it: keep the text so the speech is not lost.
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(finalText, forType: .string)
                    self.hudWindow?.showResult(finalText, status: "\(failure) — คัดลอกไว้ใน clipboard แล้ว",
                                               state: .failed)
                    self.playSound("Basso")
                } else if self.targetMode == .listen {
                    self.hudWindow?.showResult(finalText, status: "ส่ง\(place)แล้ว" + check, state: .sent)
                    self.playSound("Morse")
                } else if pasteByUser {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(finalText, forType: .string)
                    self.hudWindow?.showResult(finalText, status: "คัดลอกแล้ว — กด ⌘V เพื่อวาง" + check,
                                               state: check.isEmpty ? .copied : .warning)
                    self.playSound("Morse")
                } else if entered {
                    self.hudWindow?.showResult(finalText, status: "ส่งคำสั่งเรียบร้อย", state: .sent)
                    self.playSound("Morse")
                } else if send && !isSafe {
                    self.hudWindow?.showResult(finalText,
                                               status: "โหมดปลอดภัย (พิมพ์รอ\(place) ไม่กด Enter)" + check,
                                               state: .warning)
                    self.playSound("Morse")
                } else if send, let doubt {
                    self.hudWindow?.showResult(finalText, status: "\(doubt) — พิมพ์รอ\(place) ตรวจก่อนกด Enter",
                                               state: .warning)
                    self.playSound("Morse")
                } else {
                    self.hudWindow?.showResult(finalText, status: "พิมพ์รอ\(place) (ยังไม่กด Enter)",
                                               state: .typed)
                    self.playSound("Morse")
                }
                // Keep the result on screen briefly; a failure or a paste hint stays longer so it can be read, and a
                // send long enough for its checkmark to finish writing and settle (VoiceOrb.drawCheck).
                let shown = failure != nil ? 2.5 : pasteByUser || send && doubt != nil ? 1.5 : entered ? 1.0 : 0.6
                DispatchQueue.main.asyncAfter(deadline: .now() + shown) { NSApp.terminate(nil) }
            }
        }
    }

    // Hands how the recording ended to programs other than the target: the `listen <id>` caller's results/<id>.json
    // and, when there is text (only once dispatched), each hooks.txt command. Once per recording; every ending calls
    // it (dispatch, empty, abort, cancel).
    private func report(_ outcome: TranscriptResult.Outcome, error: String? = nil) {
        guard !isReported else { return }
        isReported = true
        result.id = resultID
        result.outcome = outcome
        result.error = error
        result.seconds = recordedSeconds > 0 ? recordedSeconds : Date().timeIntervalSince(recordingStarted)
        if let resultID {
            result.save(as: resultID)
            try? FileManager.default.removeItem(atPath: "\(Config.resultsDir)/\(resultID).pid")
        }
        if !result.text.isEmpty { runHooks(result.json) }
    }

    // Each command runs through zsh with the result on stdin, never on its command line, and is not waited for: a
    // slow or failing hook holds up neither this delivery nor the next recording.
    private func runHooks(_ data: Data) {
        let commands = ((try? String(contentsOfFile: Config.hooksPath, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        for command in commands {
            let process = Process(), input = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else {
                log("hook pid=\(getpid()) failed to start command=\"\(command)\"")
                continue
            }
            // Off this thread: a hook that never reads a result larger than the pipe holds would block it, and this
            // app's exit with it. SIGPIPE is ignored: a hook may exit without reading.
            DispatchQueue.global(qos: .utility).async {
                try? input.fileHandleForWriting.write(contentsOf: data)
                try? input.fileHandleForWriting.close()
            }
        }
    }

    // An agent's reply still being spoken would be heard by the microphone. Only a `say` is stopped: the pid in the
    // file may have been reused since.
    private func stopSpeaking() {
        guard let text = try? String(contentsOfFile: Config.speakingPath, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0, String(cString: path) == "/usr/bin/say" else { return }
        kill(pid, SIGTERM)
    }

    // Types the text into the field that has focus, as key events that carry it (the clipboard is left alone), then
    // Return when sending. Returns why nothing was typed, if so. Only called with the Accessibility permission.
    private func typeAtCursor(text: String, execute: Bool) -> String? {
        if let app = targetApp, !app.isActive {
            app.activate()
            Thread.sleep(forTimeInterval: 0.2)
        }
        // Another app took focus meanwhile (macOS may refuse the activation): the text, and a Return, would land there.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetApp?.processIdentifier else {
            return "app ที่จะพิมพ์ไม่ได้อยู่หน้าจอแล้ว"
        }
        // A password field or Secure Keyboard Entry drops posted key events without a trace.
        guard !IsSecureEventInputEnabled() else { return "มีช่องรหัสผ่านหรือ Secure Keyboard Entry เปิดอยู่" }
        let source = CGEventSource(stateID: .hidSystemState)
        func press(_ key: CGKeyCode, typing units: [UniChar] = []) {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
                event.flags = [] // the hotkey's Control/Option may still be down
                if !units.isEmpty { event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units) }
                event.post(tap: .cghidEventTap)
            }
            Thread.sleep(forTimeInterval: 0.005) // some apps drop key events that arrive faster
        }
        // An event carries at most 20 UTF-16 units; a character is never split across two. A line break would act as
        // Return, so even without `execute` the text would run.
        var units: [UniChar] = []
        for character in text {
            let next = Array((character.isNewline ? " " : String(character)).utf16)
            if !units.isEmpty, units.count + next.count > 20 { press(0, typing: units); units = [] }
            units += next
        }
        if !units.isEmpty { press(0, typing: units) }
        if execute { press(CGKeyCode(kVK_Return)) }
        return nil
    }

    // VS Code delivers the URI to its last active window; base64url keeps "&", "+" and "=" in the text intact.
    // The URI goes to the running VS Code: with several copies installed, the default scheme handler may be
    // another copy, and opening that launches a second instance instead of reaching the open windows.
    // Opening the link only proves VS Code got it; the extension's ack says where the text went: "editor", "terminal"
    // (typed), "terminal-run" (typed and Enter pressed) or "error <why>". nil: no ack, so the text may not have landed.
    private func sendToVSCode(text: String, execute: Bool) -> String? {
        guard let vscode = NSRunningApplication.runningApplications(withBundleIdentifier: Config.vscodeBundleID)
            .first?.bundleURL,
              let token = try? String(contentsOfFile: Config.uriTokenPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        let encoded = Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let ack = Self.newAckID()
        // A link VS Code handles after this recorder gave up (an "open this URI?" prompt, a slow start) must not
        // type, or run, text the user was told is on the clipboard: the extension drops it after `until`.
        let until = untilMilliseconds()
        guard let url = URL(string: "\(Config.vscodeURI)?text=\(encoded)&execute=\(execute ? 1 : 0)&token=\(token)"
                            + "&ack=\(ack)&until=\(until)")
        else { return nil }
        removeStaleAcks()

        let semaphore = DispatchSemaphore(value: 0)
        var opened = false
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: vscode, configuration: configuration) { app, error in
            opened = app != nil && error == nil
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 2.0) == .success, opened else { return nil }
        return awaitAck(ack)
    }

    // The extension's answer to a link or an inbox request, or nil when none came in time.
    private func awaitAck(_ ack: String) -> String? {
        let ackURL = URL(fileURLWithPath: Config.ackDir).appendingPathComponent(ack)
        let deadline = Date().addingTimeInterval(Config.ackTimeout)
        while Date() < deadline {
            if let outcome = try? String(contentsOf: ackURL, encoding: .utf8) {
                try? FileManager.default.removeItem(at: ackURL)
                return outcome
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    private static func newAckID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    // A recorder launched with VS Code in front asks its focused window (named in focus.json by the extension) to
    // remember where the keyboard is: the text goes there at the end even if the user has moved to another window,
    // terminal tab or app by then, and the terminal is hidden. Without such a window (the extension not loaded there)
    // the end falls back to the link, which reaches the window active at that moment.
    private func requestVSCodeSnapshot() {
        guard targetMode == .vscode, targetApp?.bundleIdentifier == Config.vscodeBundleID,
              let data = FileManager.default.contents(atPath: Config.vscodeFocusPath),
              let focus = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              focus["focused"] as? Bool == true, let pid = focus["pid"] as? Int, kill(pid_t(pid), 0) == 0,
              let window = focus["window"] as? String, UUID(uuidString: window) != nil else { return }
        let id = Self.newAckID()
        // The probe for the editor's focus borrows the clipboard: what it cannot put back is put back from here.
        let clipboard = Self.clipboardItems()
        let clipboardChange = NSPasteboard.general.changeCount
        let clipboardText = NSPasteboard.general.string(forType: .string) ?? ""
        guard writeRequest(["kind": "snapshot", "id": id, "until": untilMilliseconds()], to: window) else { return }
        vscodeSnapshotDone.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = self.awaitAck(id)
            // "error unfocused": focus.json was behind, the press was for another window; nothing was remembered.
            if let outcome, !outcome.hasPrefix("error") {
                self.vscodeSnapshot = (window, id)
                let folder = outcome.split(separator: "\t", maxSplits: 1).dropFirst().first.map(String.init)
                self.vscodeFolder = folder.flatMap { $0.hasPrefix("/") ? $0 : nil }
            }
            self.log("snapshot pid=\(getpid()) window=\(window.prefix(8)) outcome=\"\(outcome ?? "none")\"")
            DispatchQueue.main.async {
                Self.restoreProbedClipboard(clipboard, change: clipboardChange, text: clipboardText)
                self.vscodeSnapshotDone.leave()
            }
        }
    }

    // To the place the snapshot remembered, else by the link. Once a window has remembered it, the link is never the
    // fallback: it would type (and run) the text where the user is now, or a second time.
    private func deliverToVSCode(text: String, execute: Bool) -> String? {
        _ = vscodeSnapshotDone.wait(timeout: .now() + Config.ackTimeout + 1)
        guard let snapshot = vscodeSnapshot else {
            // The link's window probes the editor's focus too: put back what the probe cannot once the text landed.
            let (items, change, saved) = DispatchQueue.main.sync {
                (Self.clipboardItems(), NSPasteboard.general.changeCount,
                 NSPasteboard.general.string(forType: .string) ?? "")
            }
            let outcome = sendToVSCode(text: text, execute: execute)
            if let outcome, !outcome.hasPrefix("error") {
                DispatchQueue.main.async { Self.restoreProbedClipboard(items, change: change, text: saved) }
            }
            return outcome
        }
        let ack = Self.newAckID()
        removeStaleAcks()
        guard writeRequest(["kind": "send", "snapshot": snapshot.id, "text": text, "execute": execute,
                            "ack": ack, "until": untilMilliseconds()], to: snapshot.window) else { return nil }
        return awaitAck(ack)
    }

    // An answer the recorder no longer waits for must not act: the extension drops a request after `until`.
    private func untilMilliseconds() -> Int { Int((Date().timeIntervalSince1970 + Config.ackTimeout - 0.5) * 1000) }

    // Renamed into the window's inbox, so the extension never reads half a request.
    private func writeRequest(_ request: [String: Any], to window: String) -> Bool {
        let inbox = URL(fileURLWithPath: Config.vscodeWindowsDir).appendingPathComponent(window)
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(request["ack"] ?? request["id"] ?? "")"
        let temporary = inbox.appendingPathComponent(name + ".tmp")
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              (try? data.write(to: temporary)) != nil else { return false }
        guard rename(temporary.path, inbox.appendingPathComponent(name + ".json").path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
        return true
    }

    // An ack that came after its recorder gave up waiting.
    private func removeStaleAcks() {
        let stale = Date().addingTimeInterval(-60)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: Config.ackDir), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where ((try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantFuture) < stale {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func clipboardItems() -> [NSPasteboardItem] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    // The extension's focus probe borrows the clipboard and puts back only its text; anything else on it (an image,
    // files, rich text) is put back from here, only if what is there now is the probe's put-back text, not something
    // the user copied meanwhile.
    private static func restoreProbedClipboard(_ items: [NSPasteboardItem], change: Int, text: String) {
        guard !items.isEmpty, NSPasteboard.general.changeCount != change,
              NSPasteboard.general.string(forType: .string) ?? "" == text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(items)
    }

    // Returns why the text did not reach the session, if so.
    private func sendToTmux(text: String, execute: Bool) -> String? {
        // launchd's PATH has no Homebrew directory.
        guard let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return "ไม่พบ tmux" }
        // -l: the text as written, never read as key names ("Enter", "Up"); Enter is a key of its own.
        for keys in [["-l", "--", text]] + (execute ? [["Enter"]] : []) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tmux)
            process.arguments = ["send-keys", "-t", Config.tmuxSession] + keys
            guard (try? process.run()) != nil else { return "เรียก tmux ไม่ได้" }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "ไม่พบ tmux session \(Config.tmuxSession)" }
        }
        return nil
    }
}
