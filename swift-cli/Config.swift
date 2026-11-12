import Foundation
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
    private static let vocabularyLines = lines(of: vocabularyPaths, after: [])
    static let vocabularySentences = vocabularyLines.filter { !$0.contains(" = ") }

    // The non-empty, non-comment lines of these files that `earlier` does not already hold, each once.
    private static func lines(of paths: [String], after earlier: [String]) -> [String] {
        var seen = Set(earlier)
        return paths
            .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }.joined(separator: "\n")
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && seen.insert($0).inserted }
    }

    // "example = exam ple": what the engines keep writing for a term, replaced in the final text. A prompt
    // only nudges Whisper and Apple has no prompt, so a term they reliably mishear needs this.
    private static func parsedCorrections(_ lines: [String]) -> [(term: String, heard: [String])] {
        lines.filter { $0.contains(" = ") }.map { line in
            let parts = line.components(separatedBy: " = ")
            return (term: parts[0].trimmingCharacters(in: .whitespaces),
                    heard: parts.dropFirst().joined(separator: " = ").split(separator: ",")
                        // a one-letter spelling would replace every lone "x" or "ก" in the text
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 1 })
        }
    }
    private static let correctionLines = parsedCorrections(vocabularyLines)
    // Longest first, so "คีย์ Word ร์" is replaced before "คีย์ Word". English spellings match whole words in any case
    // (the term itself too: "EXAMPLE" -> "example"); a space in a spelling also matches no space.
    // under: lines whose spellings `lines` does not define again (a project's own reading of a spelling wins).
    private static func compiled(_ lines: [(term: String, heard: [String])],
                                 under: [(term: String, heard: [String])] = [])
        -> [(heard: NSRegularExpression, term: String)] {
        let pairs = { (lines: [(term: String, heard: [String])]) in
            lines.flatMap { line in ([line.term] + line.heard).map { (heard: $0, term: line.term) } }
        }
        let key = { (heard: String) in heard.lowercased().replacingOccurrences(of: " ", with: "") } // " " matches none
        let own = pairs(lines), taken = Set(own.map { key($0.heard) })
        return (own + pairs(under).filter { !taken.contains(key($0.heard)) })
            .sorted { $0.heard.count > $1.heard.count }
            .compactMap { pair in
                let pattern = NSRegularExpression.escapedPattern(for: pair.heard)
                    .replacingOccurrences(of: " ", with: "\\s*")
                let bounded = pair.heard.allSatisfy(\.isASCII)
                    ? "(?<![A-Za-z0-9])\(pattern)(?![A-Za-z0-9])" : pattern
                return (try? NSRegularExpression(pattern: bounded, options: .caseInsensitive)).map { ($0, pair.term) }
            }
    }
    static let corrections = compiled(correctionLines)

    // The work file of the project in `folder`: the folder's name in the characters a work file name allows, as
    // scripts/learn_edits.py's project_name names the files it writes.
    static func projectName(_ folder: String) -> String {
        (folder as NSString).lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
    }

    // The corrections for text going to `folder` (the snapshot's target): that project's work file on top of the
    // rest, its corrections only (its sentences would reach Whisper's prompt only after recognition has started). An
    // unknown folder, or one without a work file, gets the shared ones: another project's would rewrite correct words.
    static func corrections(forFolder folder: String?) -> [(heard: NSRegularExpression, term: String)] {
        guard let folder else { return corrections }
        let directory = (vocabularyPath as NSString).deletingLastPathComponent
        let own = parsedCorrections(lines(of: [directory + "/work/" + projectName(folder) + ".txt"],
                                          after: vocabularyLines))
        return own.isEmpty ? corrections : compiled(own, under: correctionLines)
    }

    // An English term inside Thai is written with a space on each side, as Whisper writes it.
    // A spelling is replaced only as whole words: "เนา" (null) is also inside "สำเนา" and "เนาะ".
    static func corrected(_ text: String, folder: String? = nil) -> String {
        corrections(forFolder: folder).reduce(text) { text, correction in
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
    // below a tenth of the loudest so far; a word quieter than that after it still counts, through Apple's text,
    // unless the enrolled microphone recorded only silence since (isSilent): Apple's text also changes when its last
    // words come late (see finishAndDispatch).
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
    // Speaker gate (see SpeakerGate): before Whisper hears a run, the parts only other voices fill are silenced, so a
    // bystander in the user's pauses does not reach Whisper's text. Each 1.5 s window, every 0.5 s, is compared with
    // the user's voiceprint (cosine). On real recordings the user's windows scored 0.4-0.7 and a bystander's 0.05-0.26
    // with CAM++ zh+en. A window with under speakerVoicedSeconds of 100 ms frames louder than speakerQuietDB is not
    // scored: silence has nothing to keep out, and a short word alone in a window scores low (0.11) as if not theirs.
    static let speakerDir = NSHomeDirectory() + "/.local/share/voice-agent/speaker"
    static let speakerThreshold: Float = 0.3
    static let speakerWindow = 24000
    static let speakerHop = 8000
    static let speakerQuietDB: Float = -50
    static let speakerVoicedSeconds = 0.5

    // Where a run of `count` samples starting at frame `offset` of the recording is scored, from the run's start: a
    // window every speakerHop of the recording (so each is scored once, while it is heard, whichever runs hold it),
    // the last ending at the run's end.
    static func speakerWindows(count: Int, offset: Int = 0) -> [Int] {
        guard count >= speakerWindow else { return [] }
        let first = firstOnGrid(offset)
        let starts = Array(stride(from: first, through: count - speakerWindow, by: speakerHop))
        return starts.last == count - speakerWindow ? starts : starts + [count - speakerWindow]
    }

    // From a run's start at frame `offset` of the recording: its first frame on the recording's speakerHop grid.
    static func firstOnGrid(_ offset: Int) -> Int {
        (offset + speakerHop - 1) / speakerHop * speakerHop - offset
    }

    // Whether a window holds speakerVoicedSeconds of 100 ms frames louder than speakerQuietDB (see speakerDir).
    static func isVoiced(_ window: ArraySlice<Float>) -> Bool {
        Double(loudFrames(window)) / 10 >= speakerVoicedSeconds
    }

    // Whether nothing in these samples is as loud as speakerQuietDB: no 100 ms frame, nor a shorter last one. On the
    // enrolled desk microphone the quiet after the last word stayed under -56 dB in 47 recordings, speech sat near
    // -28 dB, and Whisper heard none of 14 words put there under -50 dB (5 at -46 dB). Not a measure for another
    // input: a louder noise floor is never silent by this, and on a low-gain one a quiet word is.
    static func isSilent(_ samples: ArraySlice<Float>) -> Bool { loudFrames(samples) == 0 }

    // How many 100 ms frames (the last may be shorter) are not quieter than speakerQuietDB; a frame whose level
    // cannot be told (not a number) counts as loud.
    private static func loudFrames(_ samples: ArraySlice<Float>) -> Int {
        stride(from: samples.startIndex, to: samples.endIndex, by: 1600).filter { start in
            let frame = samples[start..<min(start + 1600, samples.endIndex)]
            let power = frame.reduce(0) { $0 + $1 * $1 } / Float(frame.count)
            return !(10 * log10(power + 1e-18) < speakerQuietDB)
        }.count
    }

    // The parts of a run to silence: each speakerHop block whose scored windows (a quiet one is nil) are all under
    // the threshold, and so are its neighbours'. A window half silence, half the user's first word scores low
    // (0.11), so the block next to a kept one stays: the edges of their words are kept, and so is a bystander next to
    // them: a window counted as theirs keeps every block it covers, and the neighbour rule one more (about 1 s past a
    // window with 1 s of their voice; more when a window mostly of the bystander still scores 0.3).
    // A run with no window of the user's is silenced whole: a 6 s chunk can be all bystander (the user ruled,
    // 2026-11-11). Their own voice going unrecognised is kept off by gating only the microphone they enrolled with,
    // and words Whisper then misses stay in the text from Apple's (finalText keeps what only Apple heard, but for a
    // one-word stammer). Apple's text is not gated: a bystander Apple also heard is kept the same way, so a dictation
    // held to send is then typed without Return (see doubt).
    // Blocks lie on the recording's speakerHop grid like the windows (offset: the run's first frame there), so a
    // stretch is decided alike in the runs that hold it, but at a run's edges (its last window ends at the run's end,
    // and the neighbour rule sees no block past it); the part before the run's first grid frame joins its first block
    // (no window of the run starts in it alone).
    static func silencedRanges(count: Int, starts: [Int], scores: [Float?], offset: Int = 0) -> [Range<Int>] {
        let first = firstOnGrid(offset)
        let bounds = [0] + Array(stride(from: first > 0 ? first + speakerHop : speakerHop, to: count, by: speakerHop))
            + [count]
        let blocks = Array(bounds.dropLast()), ends = Array(bounds.dropFirst())
        let others = zip(blocks, ends).map { block, end -> Bool in
            let over = zip(starts, scores).filter { $0.0 < end && $0.0 + speakerWindow > block }.compactMap(\.1)
            return !over.isEmpty && over.allSatisfy { $0 < speakerThreshold }
        }
        var ranges: [Range<Int>] = []
        for (i, block) in blocks.enumerated() where others[max(i - 1, 0)...min(i + 1, blocks.count - 1)]
            .allSatisfy({ $0 }) {
            let end = ends[i]
            if let last = ranges.last, last.upperBound == block {
                ranges[ranges.count - 1] = last.lowerBound..<end
            } else {
                ranges.append(block..<end)
            }
        }
        return ranges
    }
    // Shared with the VS Code extension: a vscode:// link from anywhere else cannot type into the terminal.
    static let uriTokenPath = NSHomeDirectory() + "/.local/share/voice-agent/uri-token"
    // The extension writes ack/<id> once it has placed the text; without it the text is kept on the clipboard.
    static let ackDir = NSHomeDirectory() + "/.local/share/voice-agent/ack"
    static let ackTimeout: TimeInterval = 4
    // `listen <id>` writes results/<id>.json (TranscriptResult) for the program that launched it, and <id>.pid while
    // it records, so that program can cancel it with SIGHUP.
    static let resultsDir = NSHomeDirectory() + "/.local/share/voice-agent/results"
    // Commands given every dictation's TranscriptResult on stdin, one per line ("#" starts a comment).
    static let hooksPath = NSHomeDirectory() + "/.config/voice-agent/hooks.txt"
    // The `say` process speaking an agent's reply (mcp/server.mjs): a recording stops it so the mic does not hear it.
    static let speakingPath = NSHomeDirectory() + "/.local/share/voice-agent/speaking.pid"
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
