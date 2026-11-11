import Cocoa
import Carbon.HIToolbox
import Speech
import AVFoundation
import CoreAudio
import NaturalLanguage

struct Config {
    static let locale = Locale(identifier: "th-TH")
    static let silenceTimeout: TimeInterval = 2.5
    static let vscodeURI = "vscode://local.voice-agent-terminal/send"
    static let vscodeBundleID = "com.microsoft.VSCode"
    static let tmuxSession = "agent"
    
    // The user's own example sentences, one per line ("#" starts a comment), read at each recording so an edit applies
    // to the next one. They replace the built-in Whisper prompt, and their English terms become hints for Apple.
    static let vocabularyPath = NSHomeDirectory() + "/.config/voice-agent/vocabulary.txt"
    private static let vocabularyPaths: [String] = {
        let directory = (vocabularyPath as NSString).deletingLastPathComponent
        let selected = try? String(contentsOfFile: directory + "/active-work.txt", encoding: .utf8)
        let work: String?
        if let selected = selected?.trimmingCharacters(in: .whitespacesAndNewlines) {
            work = selected.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) == nil
                ? nil : directory + "/work/" + selected + ".txt"
        } else {
            work = vocabularyPath
        }
        return [directory + "/common.txt", directory + "/user.txt"] + (work.map { [$0] } ?? [])
    }()
    private static let vocabularyLines: [String] = {
        var seen = Set<String>()
        return vocabularyPaths
            .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }.joined(separator: "\n")
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && seen.insert($0).inserted }
    }()
    static let vocabularySentences = vocabularyLines.filter { !$0.contains(" = ") }

    // "example = exam ple": what the engines keep writing for a term, replaced in the final text. A prompt
    // only nudges Whisper and Apple has no prompt, so a term they reliably mishear needs this.
    private static let correctionLines = vocabularyLines.filter { $0.contains(" = ") }.map { line in
        let parts = line.components(separatedBy: " = ")
        return (term: parts[0].trimmingCharacters(in: .whitespaces),
                heard: parts.dropFirst().joined(separator: " = ").split(separator: ",")
                    // a one-letter spelling would replace every lone "x" or "ก" in the text
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 1 })
    }
    // Longest first, so "คีย์ Word ร์" is replaced before "คีย์ Word". English spellings match whole words in any case
    // (the term itself too: "EXAMPLE" -> "example"); a space in a spelling also matches no space.
    static let corrections: [(heard: NSRegularExpression, term: String)] = correctionLines
        .flatMap { line in ([line.term] + line.heard).map { (heard: $0, term: line.term) } }
        .sorted { $0.heard.count > $1.heard.count }
        .compactMap { pair in
            let pattern = NSRegularExpression.escapedPattern(for: pair.heard)
                .replacingOccurrences(of: " ", with: "\\s*")
            let bounded = pair.heard.allSatisfy(\.isASCII) ? "(?<![A-Za-z0-9])\(pattern)(?![A-Za-z0-9])" : pattern
            return (try? NSRegularExpression(pattern: bounded, options: .caseInsensitive)).map { ($0, pair.term) }
        }

    // An English term inside Thai is written with a space on each side, as Whisper writes it.
    // A spelling is replaced only as whole words: "เนา" (null) is also inside "สำเนา" and "เนาะ".
    static func corrected(_ text: String) -> String {
        corrections.reduce(text) { text, correction in
            let matches = correction.heard.matches(in: text, range: NSRange(text.startIndex..., in: text))
            guard !matches.isEmpty else { return text } // tokenizing is the slow part: skip it when nothing matches
            let spaced = correction.term.allSatisfy(\.isASCII)
            let boundaries = wordBoundaries(text)
            var result = text
            for match in matches.reversed() {
                guard let found = Range(match.range, in: text),
                      boundaries.contains(found.lowerBound), boundaries.contains(found.upperBound),
                      let range = Range(match.range, in: result) else { continue }
                let wordBefore = range.lowerBound > result.startIndex
                    && result[result.index(before: range.lowerBound)].isLetter
                let wordAfter = range.upperBound < result.endIndex && result[range.upperBound].isLetter
                result.replaceSubrange(range, with: (spaced && wordBefore ? " " : "") + correction.term
                                                    + (spaced && wordAfter ? " " : ""))
            }
            return result
        }
    }

    // Where a word may start or end: between Thai words (by the system tokenizer) and where Thai meets other text.
    private static func wordBoundaries(_ text: String) -> Set<String.Index> {
        var boundaries: Set<String.Index> = [text.startIndex, text.endIndex]
        var previous: Character?
        for index in text.indices {
            let inEnglishWord = isEnglish(previous) && isEnglish(text[index])
            if let previous, !inEnglishWord, !isThai(previous) || !isThai(text[index]) { boundaries.insert(index) }
            previous = text[index]
        }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.thai)
        tokenizer.string = text
        for range in tokenizer.tokens(for: text.startIndex..<text.endIndex) {
            boundaries.insert(range.lowerBound)
            boundaries.insert(range.upperBound)
        }
        return boundaries
    }

    private static func isEnglish(_ c: Character?) -> Bool {
        c.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false
    }

    static func isThai(_ c: Character) -> Bool { c.unicodeScalars.contains { (0x0E00...0x0E7F).contains($0.value) } }

    static let contextualStrings = [
        "Claude", "Claude Code", "Aider", "refactor", "TypeScript", "Elysia", "Bun",
        "Golang", "Neo4j", "GraphRAG", "commit", "push", "pull request", "merge", "defect", "web app",
        "รันเทสต์", "แก้บั๊ก", "คอมมิต", "สร้างไฟล์", "เช็คโค้ด", "อธิบายโค้ด"
    ] + englishTerms(in: vocabularySentences + correctionLines.map(\.term))

    // Runs of English words ("web app", "API endpoint") in the given sentences.
    private static func englishTerms(in sentences: [String]) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9.+#_-]*(?: [A-Za-z][A-Za-z0-9.+#_-]*)*")
        else { return [] }
        let text = sentences.joined(separator: "\n")
        let terms = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        return Array(Set(terms))
    }
    
    static let dangerousKeywords = ["rm -rf", "drop ", "delete ", "force", "reset --hard"]

    // Whisper re-transcribes the recording at the end (a long one a chunk at a time): Apple's recognizer hears one
    // locale, so English words in Thai speech come out as Thai transliteration, while Whisper gets the English right
    // but the Thai wrong more often. The two are merged (see mergeTranscripts). Without whisper-cli or the model,
    // Apple's text is used as is.
    static let whisperCLI = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
    static let whisperServer = ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]
    // A server not answering by then (a cold disk, memory pressure) leaves the runs to whisper-cli.
    static let whisperServerStartTimeout: TimeInterval = 5
    // Full large-v3 rather than turbo: on the kept recordings its Thai is far better (CER 0.017 vs 0.061), ~1 s slower.
    static let whisperModel = NSHomeDirectory() + "/.local/share/voice-agent/ggml-large-v3-q5_0.bin"
    // Whisper copies the prompt's style, so it shows English terms in Latin script (a Thai-script example would
    // teach it to transliterate them). A term only sticks inside a sentence; appended as a list it is ignored.
    static let whisperPrompt = vocabularySentences.isEmpty ? builtInPrompt : vocabularySentences.joined(separator: ", ")
    private static let builtInPrompt = "ช่วย run test แล้ว commit แล้ว push ขึ้น branch main ให้หน่อย, "
        + "ช่วยตรวจสอบ defect ใน web app, แก้ bug ใน TypeScript แล้ว deploy ขึ้น server, "
        + "ดู log ของ API endpoint กับ database, เปิด merge request, refactor service, Claude Code"
    static let whisperVADModel = NSHomeDirectory() + "/.local/share/voice-agent/ggml-silero-v5.1.2.bin"
    static let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/voice-agent.log")
    // The latest recordings stay on disk (named in the log) so the engines can be compared on real speech.
    static let recordingsDir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches/voice-agent")
    static let recordingsKept = 200 // ~60 MB; enough to re-measure a change on real speech
    // A slow whisper-cli (cold model, busy GPU) falls back to Apple's text instead of keeping the HUD up. It takes
    // about a tenth of the recording's length when warm (75 s of speech: 7 s), so a long dictation gets more time.
    static let whisperTimeout: TimeInterval = 10
    static let whisperTimeoutPerSecond = 0.3
    // At each pause Whisper starts on all that was heard so far (in the current chunk): when nothing is said after
    // it, that run is the one the end of the recording needs, already under way (the push-to-talk key is let go
    // ~1.4 s after the last word, a tap ends silenceTimeout after it). A pause is this long with every tap buffer
    // below a tenth of the loudest so far; a word quieter than that after it still counts, through Apple's text (see
    // finishAndDispatch).
    static let pauseSeconds: TimeInterval = 0.6
    static let pauseQuietRatio: Float = 0.1
    // A long dictation is decoded a chunk at a time: the first pause once the chunk is this long ends it, that
    // pause's run is its text, and the end waits only for the last chunk. Speed first (the user's call, 2026-10-24),
    // accuracy tuned later: on the 44 reference recordings 6 s chunks cut the audio the end decodes from 16.0 s to 3.4 s
    // (p50; p90 27.3 -> 7.4 s) for merge CER 0.0360 -> 0.0399 (10 s chunks: 0.0417; closing only at a 1 s pause, as a
    // sentence end: 0.0407). A last chunk shorter than finalMinSeconds is decoded with the one before it: that is only
    // the closing pause's quiet (the key is let go ~1.4 s after the last word, a tap ends 2.5 s after it, the chunk
    // closed 0.6 s in), so the closing run, already under way, is the end's.
    static let chunkSeconds: TimeInterval = 6
    static let finalMinSeconds: TimeInterval = 2
    // One whisper-cli at a time: two large-v3 runs at once each take twice as long and ~1 GB of memory.
    static let whisperLockPath = NSHomeDirectory() + "/.local/share/voice-agent/whisper.lock"
    // Shared with the VS Code extension: a vscode:// link from anywhere else cannot type into the terminal.
    static let uriTokenPath = NSHomeDirectory() + "/.local/share/voice-agent/uri-token"
    // The extension writes ack/<id> once it has placed the text; without it the text is kept on the clipboard.
    static let ackDir = NSHomeDirectory() + "/.local/share/voice-agent/ack"
    static let ackTimeout: TimeInterval = 4
    // Written by the extension in each VS Code window: focus.json names the focused one, windows/<id>/ is its inbox.
    static let vscodeFocusPath = NSHomeDirectory() + "/.local/share/voice-agent/focus.json"
    static let vscodeWindowsDir = NSHomeDirectory() + "/.local/share/voice-agent/windows"
    // A live microphone always picks up some room noise (quietest 100 ms seen: peak 18/32767 = 0.00055); a muted or
    // not yet awake one delivers zeros (peak 1/32767), sometimes for seconds after the stream starts. Below this the
    // input is silent: the start beep waits for it, and a take that never got past it is reported, not dropped.
    static let silentInputPeak: Float = 0.0001
    static let micWakeTimeout: TimeInterval = 8
    // A session stops listening by itself after this long: in a noisy room the recognizer would keep it going.
    static let maxRecording: TimeInterval = 180
    static let logRotationBytes = 2_000_000
    // Posted by a recorder (object: its pid) when it stops listening: the listener then starts a new recording on the
    // next press, and the new recording takes Esc over from it.
    static let finishingNotification = Notification.Name("com.local.voiceagent.finishing")
    static let startedNotification = Notification.Name("com.local.voiceagent.started")
    // Microphones to record with, best first, one per line ("#" starts a comment): any part of a device's name, any
    // case. Read at each recording, so an edit applies to the next one; `voice-agent microphones` lists the names.
    static let microphonesPath = NSHomeDirectory() + "/.config/voice-agent/microphones.txt"
    static let preferredMicrophones = ((try? String(contentsOfFile: microphonesPath, encoding: .utf8)) ?? "")
        .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

// The input a recording uses. macOS makes the device plugged in last the default input, or keeps the old one, so
// following the default recorded with the wrong microphone; the recorder picks its own and leaves the default alone.
struct Microphone {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32
    let isDefault: Bool

    // Without a named one: a wired microphone (a desk mic, a headset) is the one put there to be used, then the
    // built-in, then a wireless one: AirPods' Bluetooth mic takes a moment to wake and drops their sound to call
    // quality, and an iPhone joins by itself through Continuity. A virtual or aggregate device (Teams, an app's
    // own) is silent outside its app, so it records only when named.
    var rank: Int? {
        switch transport {
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate:
            return nil
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeAirPlay,
             kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            return 1
        case kAudioDeviceTransportTypeBuiltIn:
            return 2
        default:
            return 3
        }
    }

    // The first named one present, else the best ranked; among equals the default, then the first listed.
    static func chosen(from microphones: [Microphone], preferred: [String]) -> Microphone? {
        for name in preferred {
            if let named = microphones.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) { return named }
        }
        var best: (microphone: Microphone, score: Int)?
        for microphone in microphones {
            guard let rank = microphone.rank else { continue }
            let score = rank * 2 + (microphone.isDefault ? 1 : 0)
            if score > best?.score ?? -1 { best = (microphone, score) }
        }
        return best?.microphone
    }

    // Every device with an input stream, as CoreAudio lists them.
    static func all() -> [Microphone] {
        func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope =
                     kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var defaultID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultAddress = address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectGetPropertyData(system, &defaultAddress, 0, nil, &size, &defaultID)
        var devicesAddress = address(kAudioHardwarePropertyDevices)
        guard AudioObjectGetPropertyDataSize(system, &devicesAddress, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &devicesAddress, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streamsAddress = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamsAddress, 0, nil, &streamsSize) == noErr, streamsSize > 0
            else { return nil }
            var nameAddress = address(kAudioObjectPropertyName)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr, let name
            else { return nil }
            // Left unknown (0) when it cannot be read: ranked as a wired one.
            var transportAddress = address(kAudioDevicePropertyTransportType)
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport)
            return Microphone(id: id, name: name.takeRetainedValue() as String, transport: transport,
                              isDefault: id == defaultID)
        }
    }

    var transportCode: String {
        guard transport != 0 else { return "?" }
        return String((0..<4).map { Character(UnicodeScalar(UInt8(transport >> (24 - $0 * 8) & 0xFF))) })
    }
}

enum TargetMode: String {
    case vscode = "vscode"
    case tmux = "tmux"
}

// What the HUD shows the recorder doing: the soft colours its light runs through (muted, easy on the eye), and the
// symbol the orb settles on once the outcome is known.
enum HUDState {
    case waiting, listening, transcribing, sent, typed, copied, warning, failed

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
    private static let teal = rgb(0.40, 0.82, 0.88), blue = rgb(0.44, 0.57, 0.98), violet = rgb(0.67, 0.53, 0.98)
    private static let rose = rgb(0.93, 0.57, 0.80), amber = rgb(0.93, 0.75, 0.48), coral = rgb(0.93, 0.52, 0.52)
    private static let green = rgb(0.46, 0.85, 0.66)

    var colors: [NSColor] {
        switch self {
        case .waiting: return [Self.amber, Self.rose, Self.amber]
        case .listening: return [Self.teal, Self.blue, Self.violet, Self.blue]
        case .transcribing: return [Self.violet, Self.rose, Self.blue, Self.rose]
        case .sent: return [Self.green, Self.teal]
        case .typed, .copied: return [Self.blue, Self.teal]
        case .warning: return [Self.amber, Self.coral]
        case .failed: return [Self.coral, Self.rose]
        }
    }

    // While the recorder is working the light keeps moving; an outcome holds still.
    var turnSeconds: CFTimeInterval? {
        switch self {
        case .waiting, .listening: return 5
        case .transcribing: return 1.6
        default: return nil
        }
    }

    var symbol: String? {
        switch self {
        case .waiting, .listening, .transcribing: return nil
        case .sent: return "checkmark"
        case .typed: return "text.cursor"
        case .copied: return "doc.on.clipboard"
        case .warning: return "exclamationmark"
        case .failed: return "xmark"
        }
    }

    // Only what needs a second look colours its message.
    var needsAttention: Bool { self == .warning || self == .failed }
}

// A conic gradient of the state's colours that turns, seamless where it wraps around.
class TurningGradient: CAGradientLayer {
    override init() {
        super.init()
        type = .conic
        startPoint = CGPoint(x: 0.5, y: 0.5)
        endPoint = CGPoint(x: 0.5, y: 0)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ state: HUDState) {
        colors = (state.colors + [state.colors[0]]).map(\.cgColor)
        removeAnimation(forKey: "turn")
        guard let seconds = state.turnSeconds, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * CGFloat.pi
        turn.duration = seconds
        turn.repeatCount = .infinity
        add(turn, forKey: "turn")
    }
}

// The light around the panel's edge: a thin line of the turning gradient with a soft glow inside it.
class GlowRim: NSView {
    static let radius: CGFloat = 24
    private let clip = CALayer()
    private let line = CAShapeLayer()
    private let gradient = TurningGradient()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.radius // the glow stays inside the glass, not in the window's square corners
        layer?.masksToBounds = true
        line.fillColor = nil
        line.strokeColor = NSColor.black.cgColor
        line.lineWidth = 1.5
        line.shadowColor = NSColor.black.cgColor
        line.shadowOffset = .zero
        line.shadowRadius = 7
        line.shadowOpacity = 0.9
        clip.mask = line
        clip.addSublayer(gradient)
        layer?.addSublayer(clip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = bounds
        line.frame = bounds
        line.path = CGPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: Self.radius - 0.75,
                           cornerHeight: Self.radius - 0.75, transform: nil)
        // A square over the whole panel, so the gradient covers every edge at any angle.
        let side = hypot(bounds.width, bounds.height)
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    func show(_ state: HUDState) { gradient.show(state) }
}

// A small sphere of the same light that swells with the voice; an outcome shows its symbol on it.
class VoiceOrb: NSView {
    private let sphere = CALayer()
    private let gradient = TurningGradient()
    private let icon = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        sphere.frame = bounds.insetBy(dx: 3, dy: 3)
        sphere.cornerRadius = sphere.frame.width / 2
        sphere.masksToBounds = true
        sphere.borderWidth = 1
        sphere.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        gradient.frame = sphere.bounds
        sphere.addSublayer(gradient)
        layer?.addSublayer(sphere)
        icon.frame = bounds.insetBy(dx: 7, dy: 7)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        icon.contentTintColor = .white
        addSubview(icon)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ state: HUDState) {
        gradient.show(state)
        icon.image = state.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        swell(0)
    }

    // level 0…1, as the meter reads it.
    func swell(_ level: CGFloat) {
        let level = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : level // and undo a swell left on
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        sphere.setAffineTransform(CGAffineTransform(scaleX: 1 + 0.18 * level, y: 1 + 0.18 * level))
        CATransaction.commit()
    }
}

// The microphone's level as bars, newest on the right: speech moves them, a muted or dead microphone leaves them flat.
class LevelMeter: NSView {
    private var levels = [CGFloat](repeating: 0, count: 28) // one per tap buffer (~21 ms at 48 kHz)
    // The room's level: the 10th percentile of the last ~4 s of buffers in dB, which the gaps between words reach
    // (1.5 s was all speech in a fast sentence). Recordings put it at -45…-27 dB with speech at -20 and peaks at -11,
    // so a fixed scale moved without speech; the lowest instead would hold a lone dip (-62 dB as the mic starts).
    private var recent: [Float] = []
    var latest: CGFloat { levels.last ?? 0 }

    // A buffer's peak above the room's level: 8 dB over it starts a bar, 36 dB over it fills one.
    func push(peak: Float) {
        let decibels = 20 * log10(max(peak, 1e-6))
        recent = recent.suffix(187) + [decibels]
        levels.removeFirst()
        let floor = recent.sorted()[recent.count / 10]
        levels.append(CGFloat(min(max((decibels - floor - 8) / 28, 0), 1)))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let gap: CGFloat = 2
        let width = (bounds.width - gap * CGFloat(levels.count - 1)) / CGFloat(levels.count)
        for (i, level) in levels.enumerated() {
            // Older bars fade to the left, so the sound just heard reads first.
            NSColor.white.withAlphaComponent(0.15 + 0.75 * CGFloat(i + 1) / CGFloat(levels.count)).setFill()
            let height = max(width, bounds.height * level)
            let bar = NSRect(x: CGFloat(i) * (width + gap), y: (bounds.height - height) / 2, width: width, height: height)
            NSBezierPath(roundedRect: bar, xRadius: width / 2, yRadius: width / 2).fill()
        }
    }
}

class HUDWindow: NSPanel {
    private let rim = GlowRim()
    private let orb = VoiceOrb(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
    private let statusLabel = NSTextField(labelWithString: "")
    private let meter = LevelMeter()
    private let transcriptLabel = NSTextField(wrappingLabelWithString: "แตะ: พูดจบแล้วพิมพ์รอ · กดค้าง: ปล่อยเพื่อส่ง · Esc ยกเลิก")
    // The transcript area grows upward with the text (bottom edge stays put); past the cap only the latest text shows.
    private static let minTextHeight: CGFloat = 28 // one 17 pt Thai line, so the first words do not grow it
    private static let maxTextHeight: CGFloat = 360
    private static let chromeHeight: CGFloat = 72 // status row + paddings around the transcript

    init() {
        let width: CGFloat = 560
        let height = Self.minTextHeight + Self.chromeHeight
        let contentRect = NSRect(x: 0, y: 0, width: width, height: height) // present() places it

        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.ignoresMouseEvents = true
        self.appearance = NSAppearance(named: .darkAqua) // dark glass under light text, whatever the wallpaper

        setupUI(frame: NSRect(x: 0, y: 0, width: width, height: height))
    }

    private func setupUI(frame: NSRect) {
        let glass = NSGlassEffectView(frame: frame)
        glass.cornerRadius = GlowRim.radius
        glass.tintColor = NSColor.black.withAlphaComponent(0.4)
        let content = NSView(frame: frame)
        content.autoresizingMask = [.width, .height]
        rim.frame = frame
        rim.autoresizingMask = [.width, .height]

        orb.frame.origin = NSPoint(x: 16, y: frame.height - 44)
        orb.autoresizingMask = [.minYMargin]

        meter.frame = NSRect(x: frame.width - 140, y: frame.height - 40, width: 116, height: 20)
        meter.autoresizingMask = [.minYMargin, .minXMargin]

        statusLabel.frame = NSRect(x: 54, y: frame.height - 39, width: frame.width - 210, height: 18)
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail // a long error ends in "…" instead of being cut mid-word
        statusLabel.autoresizingMask = [.minYMargin, .width]

        transcriptLabel.frame = NSRect(x: 22, y: 16, width: frame.width - 44, height: frame.height - Self.chromeHeight)
        transcriptLabel.font = NSFont.systemFont(ofSize: 13)
        transcriptLabel.textColor = NSColor.white.withAlphaComponent(0.4)
        transcriptLabel.maximumNumberOfLines = 0
        transcriptLabel.lineBreakMode = .byWordWrapping
        transcriptLabel.autoresizingMask = [.height, .width]

        show("กำลังเตรียมไมค์…", state: .waiting)
        content.addSubview(rim)
        content.addSubview(orb)
        content.addSubview(statusLabel)
        content.addSubview(meter)
        content.addSubview(transcriptLabel)
        glass.contentView = content
        self.contentView = glass
    }

    // Fades in rather than popping up over what the user is looking at.
    // Placed on the screen that is main now: a standby's HUD was built before the press, maybe on another screen.
    func present() {
        let screenRect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        setFrameOrigin(NSPoint(x: screenRect.origin.x + (screenRect.width - frame.width) / 2,
                               y: screenRect.origin.y + 90))
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().alphaValue = 1
        }
    }

    func updateTranscript(_ text: String) {
        DispatchQueue.main.async { self.setTranscript(text) }
    }

    // The first text replaces the hint and takes the transcript's larger, brighter style.
    private func setTranscript(_ text: String) {
        transcriptLabel.font = NSFont.systemFont(ofSize: 17, weight: .medium)
        transcriptLabel.textColor = .white
        let bounds = NSRect(x: 0, y: 0, width: transcriptLabel.frame.width, height: .greatestFiniteMagnitude)
        func height(of value: String) -> CGFloat {
            transcriptLabel.stringValue = value
            return transcriptLabel.cell?.cellSize(forBounds: bounds).height ?? Self.minTextHeight
        }
        var shown = text
        while height(of: shown) > Self.maxTextHeight, shown.count > 20 {
            shown = "…" + shown.dropFirst(max(shown.count / 10, 1))
        }
        let textHeight = min(max(height(of: shown), Self.minTextHeight), Self.maxTextHeight)
        var newFrame = frame
        newFrame.size.height = textHeight + Self.chromeHeight
        setFrame(newFrame, display: true)
    }

    private func show(_ status: String, state: HUDState) {
        statusLabel.stringValue = status
        statusLabel.textColor = state.needsAttention ? state.colors[0] : NSColor.white.withAlphaComponent(0.6)
        rim.show(state)
        orb.show(state)
    }

    func showStatus(_ status: String, state: HUDState) {
        DispatchQueue.main.async { self.show(status, state: state) }
    }

    func showLevel(peak: Float) {
        DispatchQueue.main.async {
            self.meter.push(peak: peak)
            self.orb.swell(self.meter.latest)
        }
    }

    func showResult(_ text: String, status: String, state: HUDState) {
        DispatchQueue.main.async {
            self.meter.isHidden = true // listening is over: the status (a long error or hint) takes the meter's place
            self.statusLabel.frame.size.width = self.meter.frame.maxX - self.statusLabel.frame.minX
            self.show(status, state: state)
            self.setTranscript(text)
        }
    }
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
    // Where the text goes in vscode mode: the app that had focus when the hotkey was pressed (this recorder opens
    // without taking it). VS Code gets it in its terminal through the extension; any other app at its cursor.
    private var targetApp = NSWorkspace.shared.frontmostApplication // a standby's is read again at the press
    // In VS Code, the window and the place in it (terminal tab, editor cursor) that had the keyboard then, as that
    // window's extension remembered it: set before vscodeSnapshotDone is left, nil when no window took the snapshot.
    private var vscodeSnapshot: (window: String, id: String)?
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

    // A standby is launched ahead of the press by the hotkey listener (its pid), so the press skips the app's launch:
    // it waits, off the microphone and off screen, for SIGUSR2 and only then starts like a fresh recorder.
    private let standbyFor: pid_t?
    private var isStandby: Bool
    private var listenerExit: DispatchSourceProcess?
    private var standbyActivity: NSObjectProtocol?
    private var didFinishLaunching = false
    private var tink: NSSound? // loaded ahead: afplay took up to 0.4 s to start, after the mic was already live

    init(mode: TargetMode, standbyFor listener: pid_t? = nil) {
        self.targetMode = mode
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
                    if let change = self.startChange(from: current, to: segment) {
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
        let start = closes ? open : runStart(upTo: frames, chunkStarts: chunkStarts)
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
            let text = Self.writeWAV(samples, to: self.pauseWAV)
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

    // On whisperQueue: the end's run, on heard[start...]. From the start that is the recording's own file.
    private func transcribeEnd(_ heard: [Float], from start: Int) -> String? {
        guard start > 0 else { return transcribeWithWhisper(whisperURL, seconds: recordedSeconds) }
        defer { try? FileManager.default.removeItem(at: pauseWAV) }
        let samples = Array(heard[start...])
        return Self.writeWAV(samples, to: pauseWAV)
            ? transcribeWithWhisper(pauseWAV, seconds: Double(samples.count) / 16000) : nil
    }

    // A 16 kHz WAV for whisper-cli, closed (its header written) on return.
    private static func writeWAV(_ samples: [Float], to url: URL) -> Bool {
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
        let lockDeadline = Date().addingTimeInterval(Config.whisperTimeout)
        while lock >= 0, flock(lock, LOCK_EX | LOCK_NB) != 0 {
            processLock.lock()
            let waiting = wanted()
            processLock.unlock()
            guard waiting, Date() < lockDeadline else { return nil }
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
    // 2.7 s recording, measured twice). A second of silence, decoded without VAD (which would skip it: 0.01 s), is
    // that first run, as the recording starts; taking the first snapshot, starting the end or Esc stops it while it
    // is under way (stopWarmUp; the server drops it, and the next run pays ~0.1 s for that). Skipped when another
    // process holds the Whisper lock: the GPU is busy, so warm. The lock is held through this server's load (~0.6 s)
    // too; another recorder's run waits that long for it.
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
            guard Self.writeWAV([Float](repeating: 0, count: 16000), to: self.pauseWAV) else { return }
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
    // warmUp: the run is warmWhisperServer's, decoded without VAD (which would skip its silence) and not counted.
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

    // Where a run on heard16k up to `frames` starts, the same for a pause's run and the end's, so the end can use
    // the last pause's: the open chunk, or the one before too when the open one is too short.
    private func runStart(upTo frames: Int, chunkStarts: [Int]) -> Int {
        let last = chunkStarts.count - 1
        let short = Double(frames - chunkStarts[last]) < Config.finalMinSeconds * 16000
        return last > 0 && short ? chunkStarts[last - 1] : chunkStarts[last]
    }

    // The closed chunks' texts before the end's run, and where that run starts: a chunk whose run failed is decoded
    // again with it, and so is every one after it.
    private func endChunks(_ texts: [String?], chunkStarts: [Int], runStart: Int) -> (start: Int, texts: [String]) {
        let used = texts.prefix(chunkStarts.firstIndex(of: runStart) ?? 0)
        guard let failed = used.firstIndex(where: { $0 == nil }) else { return (runStart, used.compactMap { $0 }) }
        return (chunkStarts[failed], used[..<failed].compactMap { $0 })
    }

    // Whisper sometimes loops and emits a phrase twice in a row; keep one copy of any repeated run of 6+ characters.
    private func collapseRepeats(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(.{6,}?)\\1+") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
    }

    // When the recognizer's text since its last restart changes its start: "restart" or "revise" (nil: same start).
    // After a pause the on-device recognizer may start its text over without finalising: a shorter text with a
    // different start ("สามารถจัดการ" -> "ออกแบบ"), new speech. A revision hears the same audio again, so it is about
    // as long and may reuse what it had ("พิจารณาเรื่อง" -> "เรื่องของ"; keeping that would repeat the words). A start
    // under half as long is new speech even when its first letters occur in the old text: read as a revision it
    // dropped whole sentences ("…ต้องเขียนให้ชัดเจน…" -> "เขียน"); a revision read as a restart only repeats words.
    // A revision may rewrite only its first words, in either script ("การการให้" -> "จัดการให้", "Velge เกตเวย์" ->
    // "เวลเกตเวย์"): an ending of 3+ characters (any case; a mark counts with its letter) shared over at least half the
    // new text, at 2/3 the old length or more, is the same audio ("จัดการให้เลย" -> "ทำต่อเลย" shares "เลย" but is new
    // speech). New speech ending in the old words ("ช่วยดูให้หน่อยนะครับ" -> "แก้ให้หน่อยนะครับ") is lost the same way;
    // none of 1469 logged restarts was one, while 43 were revisions that repeated their misheard start.
    private func startChange(from current: String, to segment: String) -> String? {
        guard current.count >= 4, !segment.hasPrefix(String(current.prefix(2))) else { return nil }
        let sharedEnding = zip(current.reversed(), segment.reversed())
            .prefix { $0.lowercased() == $1.lowercased() }.count
        let sameEnding = sharedEnding >= 3 && sharedEnding * 2 >= segment.count
            && segment.count * 3 >= current.count * 2
        let restarted = segment.count < current.count && (segment.count * 2 < current.count
            || (!current.contains(String(segment.prefix(4))) && !sameEnding))
        return restarted ? "restart" : "revise"
    }

    // Units for the alignment: an English word (a run of ASCII letters/digits), a Thai word, or any other character.
    // Whole words keep the texts from aligning on a letter two different words share: "Refresh" + "defeat" made
    // "defreat", and Apple's "แอลแอลเอ็ม" against Whisper's "llm" left "run llm เอ็มเอง". English is split off before
    // the Thai tokenizer, which drops some lowercase English words.
    private func mergeUnits(_ text: String) -> [String] {
        var units: [String] = [], word = "", thai = ""
        func flushThai() { units += thaiWords(thai); thai = "" }
        for c in text {
            if c.isASCII && (c.isLetter || c.isNumber) { flushThai(); word.append(c); continue }
            if !word.isEmpty { units.append(word); word = "" }
            if Config.isThai(c) { thai.append(c) } else { flushThai(); units.append(String(c)) }
        }
        flushThai()
        if !word.isEmpty { units.append(word) }
        return units
    }

    private func thaiWords(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.thai)
        tokenizer.string = text
        var words: [String] = [], position = text.startIndex
        for range in tokenizer.tokens(for: text.startIndex..<text.endIndex) {
            if position < range.lowerBound { words.append(String(text[position..<range.lowerBound])) } // e.g. "ๆ"
            words.append(String(text[range]))
            position = range.upperBound
        }
        if position < text.endIndex { words.append(String(text[position...])) }
        return words
    }

    // Apple writes a repeated word twice ("หลายหลายครั้ง", "นิดนิดนิดหน่อยหน่อย") where Whisper writes "หลายๆ": mark
    // the repeat the same way so the two align. Only the words Whisper marks: "ของของฉัน" is a stammer. On the text,
    // not the units: the tokenizer splits "หลายหลายครั้ง" as "หลาย|หลายครั้ง".
    private func repetitionMarked(_ apple: String, as whisper: String) -> String {
        // The tokenizer gives "หลาย|ๆ" or, for some words, "จริงๆ".
        let units = mergeUnits(whisper).filter { !$0.allSatisfy(\.isWhitespace) }
        let marked = zip(units, units.dropFirst()).compactMap { $1 == "ๆ" ? $0 : nil }
            + units.compactMap { $0.count > 1 && $0.hasSuffix("ๆ") ? String($0.dropLast()) : nil }
        return Set(marked.filter { $0.contains(where: Config.isThai) }).reduce(apple) { text, word in
            let pattern = "(?:\(NSRegularExpression.escapedPattern(for: word))){2,}"
            return text.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: word + "ๆ"),
                                             options: .regularExpression)
        }
    }


    // How many "not"s the text holds. "ไม่ว่า" (no matter; Apple's "แม้ว่า" for it was right) and "อย่าง" (like) are
    // not ones, "ไม่ว่าง" (busy) is.
    private func negations(_ text: String) -> Int {
        let count = { (words: [String]) in words.reduce(0) { $0 + text.components(separatedBy: $1).count - 1 } }
        return count(["ไม่", "อย่า", "ไม่ว่าง"]) - count(["ไม่ว่า", "อย่าง"])
    }

    // Apple's Thai with Whisper's English: align the two texts (LCS over mergeUnits, case-insensitive); where they
    // differ, take Whisper's span when it holds Latin letters (an English term Apple transliterated) or a negation
    // Apple's lacks, else Apple's.
    // trusted: Whisper's text was used, not Apple's alone because Whisper heard something else.
    private func mergeTranscripts(apple: String, whisper: String) -> (text: String, trusted: Bool) {
        let a = mergeUnits(repetitionMarked(apple, as: whisper)), w = mergeUnits(whisper)
        let key = { (unit: String) in unit.lowercased() }
        var lcs = Array(repeating: Array(repeating: 0, count: w.count + 1), count: a.count + 1)
        // A space is not a word both heard: as an anchor it split "พิมพ์ Preme" from "implement" and kept "พิมพ์".
        let same = { (i: Int, j: Int) in !a[i].allSatisfy(\.isWhitespace) && key(a[i]) == key(w[j]) }
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: w.count - 1, through: 0, by: -1) {
                lcs[i][j] = same(i, j) ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        let thaiCount = { (text: String) in text.filter(Config.isThai).count }
        // Apple's "ใหม่" where Whisper has "ไม่" is a tone either of them may have misheard, not a dropped "not". So
        // are "หมาย" and "มี": "หน่วงหมายถึง" came out "นวงไม่ถึง", "ยังมีหน่วง" came out "ยังไม่นวง" (lag reported
        // as none). Not when Whisper's span holds the word too: "ไม่มีปัญหา" for Apple's "มีปัญหา" is a real "not".
        // Matched inside words ("เป้าหมาย"). A "ไม่" Apple heard as "มี" ("มีต้องแก้") keeps Apple's: replayed on 888
        // logged dictations, this changed 3, each a "not" Whisper made up ("และมีประสิทธิภาพ").
        let soundsLikeNot = ["ใหม่", "ไหม", "มั้ย", "มั๊ย", "ไม้", "ไหม้", "หมาย", "มี"]
        var merged = "", appleSpan = "", whisperSpan = "", lastWord = "", addedAtEnd = ""
        func flush(atEnd: Bool = false, next: String = "") {
            let appleWord = appleSpan.trimmingCharacters(in: .whitespaces)
            let whisperWord = whisperSpan.trimmingCharacters(in: .whitespaces)
            func repeatsNeighbour(_ units: [String]) -> Bool { units.first == next || units.last == lastWord }
            if atEnd, appleSpan.allSatisfy(\.isWhitespace), whisperSpan.first?.isWhitespace ?? true {
                merged += appleSpan // a phrase only Whisper heard at the end is one it added: "Thank you." (not ".md")
                addedAtEnd = whisperSpan
            } else if whisperSpan.contains(where: { $0.isASCII && $0.isLetter }) {
                let span = englishSpan(whisper: whisperSpan, apple: appleSpan, atEnd: atEnd)
                merged += span.text
                addedAtEnd = span.dropped
            } else if !appleWord.isEmpty, whisperSpan.allSatisfy(\.isWhitespace),
                      appleWord == lastWord || appleWord == next {
                merged += whisperSpan // a stammer only Apple kept: "ของของฉัน", "ปรับปรับปรุง"
            } else if !atEnd, appleSpan.allSatisfy(\.isWhitespace), thaiCount(whisperSpan) >= 5 {
                // Words Apple dropped ("พิจารณา" before "เรื่องของ…"), but not at the end, where Whisper tends to add
                // a phrase nobody said.
                merged += whisperSpan
            } else if negations(whisperSpan) > negations(appleSpan),
                      !soundsLikeNot.contains(where: { appleSpan.contains($0) && !whisperSpan.contains($0) }),
                      !appleWord.contains(where: \.isLetter)
                        ? thaiCount(whisperSpan) < 5 && !repeatsNeighbour(mergeUnits(whisperWord))
                        : whisperSpan.count <= appleSpan.count * 2 {
                // A "not" only Whisper heard turns the meaning around: "อย่าแก้" heard as "อยากแก้", "ทำได้ไม่สมบูรณ์
                // 100%" as "ทำได้ร้อยเปอร์เซ็นต์", "ไม่ได้ทำ" as "ทำ". Where Apple heard no word, only a word or two
                // (longer ones are the branch above; at the end they are Whisper's addition: "เสร็จแล้วนะ ไม่ต้องห่วง")
                // that do not repeat their neighbours ("ไม่ ไม่ไป", "ไม่ไป ไม่ไป" are Whisper repeating itself); where
                // Apple heard other words, only about as many (a longer span is more than the "not": Whisper said the
                // sentence twice). Meaning goes before spelling: "Build ได้" for "บิวด์ไม่ได้" loses the English term.
                merged += whisperSpan
            } else {
                merged += appleSpan
            }
            appleSpan = ""; whisperSpan = ""
        }
        var i = 0, j = 0
        while i < a.count || j < w.count {
            if i < a.count, j < w.count, same(i, j) {
                flush(next: a[i]); merged += a[i]; lastWord = a[i]; i += 1; j += 1
            } else if j < w.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] {
                whisperSpan += w[j]; j += 1
            } else {
                appleSpan += a[i]; i += 1
            }
        }
        flush(atEnd: true)
        // How much of the Thai both heard, by character: a word that differs in one letter ("ทอด"/"ถอด") still counts.
        // A phrase Whisper added at the end is already dropped and does not count against it, unless it was all of
        // Whisper's Thai: then nothing is left to compare ("test ทดสอบ" for "เทสต์เทสต์" is not one Apple missed).
        let added = addedAtEnd.filter(Config.isThai), allHeard = whisper.filter(Config.isThai)
        let kept = allHeard.hasSuffix(added) ? String(allHeard.dropLast(added.count)) : allHeard
        let heard = kept.isEmpty ? allHeard : kept
        let appleThai = thaiCount(apple), whisperThai = heard.count
        let sharedThai = sharedCount(Array(apple.filter(Config.isThai)), Array(heard))
        let result = merged.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        // Apple missed part of the speech and the merge filled it from Whisper: keep that even though little of
        // Whisper's Thai matched Apple's (the check below), as long as Whisper also holds most of what Apple heard.
        if apple.count * 10 < result.count * 7, sharedThai * 10 >= appleThai * 6 { return (result, true) }
        // Whisper heard something else (it hallucinates on short or unclear speech: "ทำต่อ" became "ที่นี่ รับทราบ"):
        // keep Apple's text. An English-only result has no Thai to agree on: trust it only when the prompt teaches
        // every word in it.
        let vocabulary = Set(mergeUnits(Config.whisperPrompt.lowercased()))
        let knownEnglish = w.allSatisfy {
            !($0.first?.isLetter ?? false) || thaiCount($0) > 0 || vocabulary.contains(key($0))
        }
        if whisperThai == 0 ? appleThai > 0 && !knownEnglish : sharedThai * 2 < whisperThai {
            return (apple, false)
        }
        return (result, true)
    }

    // The text delivered, from Apple's and Whisper's (repeats collapsed; nil: none), and how the merge took Whisper's.
    // Both sides are corrected first, so a fixed term lines up as one word in the merge.
    private func finalText(apple: String, whisper: String?) -> (text: String, trusted: Bool) {
        guard let whisper else { return (Config.corrected(apple), true) }
        let merged = mergeTranscripts(apple: Config.corrected(apple), whisper: Config.corrected(whisper))
        return (Config.corrected(merged.text), merged.trusted)
    }

    // Whisper's span with an English term, but with Apple's Thai word at either edge when Whisper's is only a
    // misspelling of it: "ตรวจสอบ Refresh ค้าง" vs "ตัวดสอบ defeat ทาง" gives "ตรวจสอบ defeat ค้าง".
    private func englishSpan(whisper: String, apple: String, atEnd: Bool) -> (text: String, dropped: String) {
        let words = whisper.split(separator: " ").map(String.init)
        let appleWords = apple.split(separator: " ").map(String.init)
        guard let first = words.firstIndex(where: { $0.contains { $0.isASCII && $0.isLetter } }),
              let last = words.lastIndex(where: { $0.contains { $0.isASCII && $0.isLetter } })
        else { return (whisper, "") }
        var edited = words, dropped = ""
        if appleWords.count > 1, first > 0, let head = appleWords.first, alike(words[..<first].joined(), head) {
            edited.replaceSubrange(..<first, with: [head])
        }
        let tail = last + 1 - (words.count - edited.count)
        if last + 1 < words.count {
            if appleWords.count > 1, let end = appleWords.last, alike(words[(last + 1)...].joined(), end) {
                edited.replaceSubrange(tail..., with: [end])
            } else if atEnd {
                // Thai after the last English word, at the very end, that Apple mostly did not hear there is a
                // phrase Whisper added: "… branch main ขอบคุณที่รับชม" (but "time ต่อ" for Apple's "ทำต่อ" stays).
                // By code point: "นั้" and "นี้" are one Character each, so one vowel would make the syllable differ.
                let consonants = { (text: String) in
                    text.unicodeScalars.filter { (0x0E01...0x0E2E).contains($0.value) }.map(Character.init)
                }
                let added = consonants(words[(last + 1)...].joined())
                if !added.isEmpty, sharedCount(added, consonants(apple)) * 2 < added.count {
                    dropped = words[(last + 1)...].joined(separator: " ")
                    edited.removeSubrange(tail...)
                }
            }
        }
        let lead = whisper.prefix { $0 == " " }, trail = whisper.reversed().prefix { $0 == " " }
        return (lead + edited.joined(separator: " ") + String(trail), dropped)
    }

    // Two spellings of one Thai word: at least half their characters, in order, are shared.
    private func alike(_ x: String, _ y: String) -> Bool {
        let a = Array(x), b = Array(y)
        guard let p = a.first, let q = b.first, Config.isThai(p), Config.isThai(q) else { return false }
        return sharedCount(a, b) * 4 >= a.count + b.count
    }

    private func sharedCount(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(repeating: 0, count: b.count + 1)
        for x in a {
            var diagonal = 0
            for (j, y) in b.enumerated() {
                let above = row[j + 1]
                row[j + 1] = x == y ? diagonal + 1 : max(row[j + 1], row[j])
                diagonal = above
            }
        }
        return row[b.count]
    }

    // Why a transcript should wait for the user's look instead of being sent (nil: send it). whisper: Whisper's text,
    // nil when it failed (for a chunked dictation: on the last chunk), "" when it heard nothing. On 213 sent dictations
    // these held 13-14 (the log writes a failed run and an empty one alike), the ones Whisper did not save ("Bergman"
    // for "fix", "อัปเดต MR Decision" for "Update MR description"). The learner's other signs were left out: a lone
    // letter or odd casing was mostly right ("เลือก A", "Column D"), and Whisper's English missing from the text
    // happened only where the merge kept Apple's. Both engines mishearing alike ("บันสตาร์" for "Bun start") shows in
    // none of them.
    private func doubt(apple: String, whisper: String?, final: (text: String, trusted: Bool)) -> String? {
        guard let whisper else { return "Whisper ถอดไม่ได้" }
        guard !whisper.isEmpty else { return "Whisper ไม่ได้ยินอะไร" }
        guard final.trusted else { return "Apple กับ Whisper ได้ยินไม่ตรงกัน" }
        // Whisper's English span took the place of Apple's "not" ("Build ได้" for "บิวด์ไม่ได้"): the meaning turned
        // around. None in the logged dictations, but the costliest error to send.
        return negations(final.text) < negations(Config.corrected(apple)) ? "คำว่า \"ไม่\" หายไป" : nil
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
        // the pause, nor (for a quieter word) heard by Apple.
        let snapshot = spokeSinceSnapshot || snapshotFrames == 0 ? nil : snapshotFrames
        let reusable = snapshot != nil && transcriptAtSnapshot.map(Self.spoken) == Self.spoken(latestTranscript)
        // The WAV is closed: nothing is appended any more, so this is all of it, shared without a copy. When the last
        // pause's run stands for the recording, the end's starts where that one did (not on the quiet after it).
        let heard = heard16k, starts = chunkStarts
        let start = runStart(upTo: reusable ? snapshotFrames : heard.count, chunkStarts: starts)
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
            log("empty pid=\(getpid()) send=\(send) seconds=\(Int(recordedSeconds)) peak=\(peak) "
                + "input=\"\(inputDeviceName)\"")
            if peak < Config.silentInputPeak, recordedSeconds >= 1 {
                abort("ไมค์ไม่มีเสียงเข้ามา (\(inputDeviceName)) — ลองพูดใหม่ "
                      + "หรือเลือกไมค์ใน ~/.config/voice-agent/microphones.txt")
            } else {
                NSApp.terminate(nil) // nothing said: no error sound
            }
            return
        }

        hudWindow?.showResult(appleText, status: "กำลังถอดความ… (Esc ยกเลิก)", state: .transcribing)
        let started = Date()
        whisperQueue.async { // after the pause's run, if one is under way, and every closed chunk's
            let (from, chunks) = self.endChunks(self.chunkTexts, chunkStarts: starts, runStart: start)
            let last = self.snapshotText
            let early = reusable && last?.frames == snapshot && last?.start == from ? last?.text : nil
            let tail = early ?? self.transcribeEnd(heard, from: from)
            let parts = chunks + (tail.map { [$0] } ?? [])
            let text = parts.isEmpty ? nil : parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let whisperText = text.flatMap { $0.isEmpty ? nil : self.collapseRepeats($0) }
            let whisperInstalled = Config.whisperCLI.contains { FileManager.default.isExecutableFile(atPath: $0) }
                && FileManager.default.fileExists(atPath: Config.whisperModel)
            // The log keeps the raw texts, so new mishearings can be added to the vocabulary.
            let final = self.finalText(apple: appleText, whisper: whisperText)
            let finalText = final.text
            // Without Whisper installed Apple's text is all there is: sent as before.
            let doubt = send && whisperInstalled
                ? self.doubt(apple: appleText, whisper: tail == nil ? nil : whisperText ?? "", final: final) : nil
            self.pruneRecordings()
            self.log("file=\(self.whisperURL.lastPathComponent) send=\(send) engine=\(whisperText == nil ? "apple" : "merged") "
                + "whisper_ms=\(Int(Date().timeIntervalSince(started) * 1000)) apple=\"\(appleText)\" "
                + "whisper=\"\(whisperText ?? "")\" final=\"\(finalText)\" "
                + "starts=\"\(self.startChanges.joined(separator: " | "))\" "
                + "early=\(early != nil) pause_runs=\(self.pauseRuns) server_runs=\(self.serverRuns) "
                + "cli_runs=\(self.cliRuns) warm=\(self.warm) chunks=\(chunks.count) held=\"\(doubt ?? "")\"")
            self.stopWhisperServer() // the last run is over: give its memory back before the text is delivered
            DispatchQueue.main.async { self.dispatch(finalText, send: send, doubt: doubt) }
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
    private func dispatch(_ finalText: String, send: Bool, doubt: String? = nil) {
        guard !isDispatched else { return } // cancelled while Whisper ran
        isDispatched = true
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
            }
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
                // Keep the result on screen briefly; a failure or a paste hint stays longer so it can be read.
                let shown = failure != nil ? 2.5 : pasteByUser || send && doubt != nil ? 1.5 : 0.6
                DispatchQueue.main.asyncAfter(deadline: .now() + shown) { NSApp.terminate(nil) }
            }
        }
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
            if let outcome, !outcome.hasPrefix("error") { self.vscodeSnapshot = (window, id) }
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
    let delegate = AppDelegate(mode: TargetMode(rawValue: modeArg) ?? .vscode, standbyFor: standbyFor)
    // Before app.run, so the hotkey listener can signal as soon as the app reports it finished launching.
    delegate.setupSignalHandlers()
    app.delegate = delegate
    app.run()
}
