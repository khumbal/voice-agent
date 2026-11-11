import Foundation
import NaturalLanguage

// What a recording came to, for programs other than the one it types into: `listen <id>` writes it to
// Config.resultsDir/<id>.json, and every hooks.txt command gets it on stdin. A program should act on the text only
// when outcome is "done", intent is "send" and holds is empty; holds are why the app itself would not press Return.
struct TranscriptResult {
    enum Outcome: String { case done, cancelled, empty, failed }
    var id: String?
    var outcome = Outcome.cancelled
    var text = "", apple = "", whisper: String?
    var send = false
    var holds: [String] = []
    var error: String? // failed: why
    var seconds: TimeInterval = 0

    var json: Data {
        var object: [String: Any] = ["v": 1, "outcome": outcome.rawValue, "text": text, "apple": apple,
                                     "whisper": whisper ?? NSNull(), "intent": send ? "send" : "type",
                                     "holds": holds,
                                     "seconds": NSDecimalNumber(string: String(format: "%.1f", seconds))] // not 2.2999…
        object["id"] = id
        object["error"] = error
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        return (try? JSONSerialization.data(withJSONObject: object, options: options)) ?? Data()
    }

    // results/<id>.json for `listen <id>`: written whole, then renamed, so its reader never sees half of it.
    func save(as id: String) {
        let path = "\(Config.resultsDir)/\(id)"
        if (try? json.write(to: URL(fileURLWithPath: path + ".tmp"))) != nil { rename(path + ".tmp", path + ".json") }
    }
}

// The text side of a recording: Apple's and Whisper's transcripts merged, checked and split into runs.
// Pure functions of their arguments, so the tests run them as shipped (tests/mkharness.py).
enum Transcript {
    // Where a run on heard16k up to `frames` starts, the same for a pause's run and the end's, so the end can use
    // the last pause's: the open chunk, or the one before too when the open one is too short.
    static func runStart(upTo frames: Int, chunkStarts: [Int]) -> Int {
        let last = chunkStarts.count - 1
        let short = Double(frames - chunkStarts[last]) < Config.finalMinSeconds * 16000
        return last > 0 && short ? chunkStarts[last - 1] : chunkStarts[last]
    }

    // The closed chunks' texts before the end's run, and where that run starts: a chunk whose run failed is decoded
    // again with it, and so is every one after it.
    static func endChunks(_ texts: [String?], chunkStarts: [Int], runStart: Int) -> (start: Int, texts: [String]) {
        let used = texts.prefix(chunkStarts.firstIndex(of: runStart) ?? 0)
        guard let failed = used.firstIndex(where: { $0 == nil }) else { return (runStart, used.compactMap { $0 }) }
        return (chunkStarts[failed], used[..<failed].compactMap { $0 })
    }

    // Whisper sometimes loops and emits a phrase twice in a row; keep one copy of any repeated run of 6+ characters.
    static func collapseRepeats(_ text: String) -> String {
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
    static func startChange(from current: String, to segment: String) -> String? {
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
    static func mergeUnits(_ text: String) -> [String] {
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

    static func thaiWords(_ text: String) -> [String] {
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
    static func repetitionMarked(_ apple: String, as whisper: String) -> String {
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
    static func negations(_ text: String) -> Int {
        let count = { (words: [String]) in words.reduce(0) { $0 + text.components(separatedBy: $1).count - 1 } }
        return count(["ไม่", "อย่า", "ไม่ว่าง"]) - count(["ไม่ว่า", "อย่าง"])
    }

    // Apple's Thai with Whisper's English: align the two texts (LCS over mergeUnits, case-insensitive); where they
    // differ, take Whisper's span when it holds Latin letters (an English term Apple transliterated) or a negation
    // Apple's lacks, else Apple's.
    // trusted: Whisper's text was used, not Apple's alone because Whisper heard something else. appleOnly: the text
    // keeps words where Whisper heard none.
    static func mergeTranscripts(apple: String, whisper: String) -> (text: String, trusted: Bool, appleOnly: Bool) {
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
        var merged = "", appleSpan = "", whisperSpan = "", lastWord = "", addedAtEnd = "", appleOnly = false
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
                // Whisper's span may hold the full stop it puts at a silenced stretch.
                let word = { (c: Character) in c.isLetter || c.isNumber }
                if !whisperSpan.contains(where: word), appleWord.contains(where: word) { appleOnly = true }
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
        if apple.count * 10 < result.count * 7, sharedThai * 10 >= appleThai * 6 { return (result, true, appleOnly) }
        // Whisper heard something else (it hallucinates on short or unclear speech: "ทำต่อ" became "ที่นี่ รับทราบ"):
        // keep Apple's text. An English-only result has no Thai to agree on: trust it only when the prompt teaches
        // every word in it.
        let vocabulary = Set(mergeUnits(Config.whisperPrompt.lowercased()))
        let knownEnglish = w.allSatisfy {
            !($0.first?.isLetter ?? false) || thaiCount($0) > 0 || vocabulary.contains(key($0))
        }
        if whisperThai == 0 ? appleThai > 0 && !knownEnglish : sharedThai * 2 < whisperThai {
            return (apple, false, false)
        }
        return (result, true, appleOnly)
    }

    // The text delivered, from Apple's and Whisper's (repeats collapsed; nil: none), and how the merge took Whisper's.
    // Both sides are corrected first, so a fixed term lines up as one word in the merge.
    static func finalText(apple: String, whisper: String?) -> (text: String, trusted: Bool, appleOnly: Bool) {
        guard let whisper else { return (Config.corrected(apple), true, false) }
        let merged = mergeTranscripts(apple: Config.corrected(apple), whisper: Config.corrected(whisper))
        return (Config.corrected(merged.text), merged.trusted, merged.appleOnly)
    }

    // Whisper's span with an English term, but with Apple's Thai word at either edge when Whisper's is only a
    // misspelling of it: "ตรวจสอบ Refresh ค้าง" vs "ตัวดสอบ defeat ทาง" gives "ตรวจสอบ defeat ค้าง".
    static func englishSpan(whisper: String, apple: String, atEnd: Bool) -> (text: String, dropped: String) {
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
    static func alike(_ x: String, _ y: String) -> Bool {
        let a = Array(x), b = Array(y)
        guard let p = a.first, let q = b.first, Config.isThai(p), Config.isThai(q) else { return false }
        return sharedCount(a, b) * 4 >= a.count + b.count
    }

    static func sharedCount(_ a: [Character], _ b: [Character]) -> Int {
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
    // silenced: the speaker gate silenced another voice for Whisper in this recording.
    static func doubt(apple: String, whisper: String?, final: (text: String, trusted: Bool, appleOnly: Bool),
                       silenced: Bool = false) -> String? {
        guard let whisper else { return "Whisper ถอดไม่ได้" }
        guard !whisper.isEmpty else { return "Whisper ไม่ได้ยินอะไร" }
        guard final.trusted else { return "Apple กับ Whisper ได้ยินไม่ตรงกัน" }
        // Whisper's English span took the place of Apple's "not" ("Build ได้" for "บิวด์ไม่ได้"): the meaning turned
        // around. None in the logged dictations, but the costliest error to send.
        if negations(final.text) < negations(Config.corrected(apple)) { return "คำว่า \"ไม่\" หายไป" }
        // Words only Apple heard, in a recording where another voice was silenced for Whisper: Apple's text is not
        // gated, so they may be that voice's. Held, not dropped: they may as well be the user's own (the user ruled,
        // 2026-11-11).
        return silenced && final.appleOnly ? "มีเสียงคนอื่นแทรก คำที่ Apple ได้ยินฝ่ายเดียวอาจเป็นของเขา" : nil
    }

    // A finished dictation for other programs, and the doubt that holds its Return back on a send. The doubt is
    // worked out on every dictation: a typed one's holds still tell a program not to act on it unasked.
    // whisper: what Whisper heard, nil when it failed; installed: false without Whisper, whose text is then Apple's.
    static func result(final: (text: String, trusted: Bool, appleOnly: Bool), apple: String, whisper: String?,
                       installed: Bool, send: Bool, silenced: Bool) -> (result: TranscriptResult, doubt: String?) {
        let held = installed ? doubt(apple: apple, whisper: whisper, final: final, silenced: silenced) : nil
        let result = TranscriptResult(text: final.text, apple: apple, whisper: whisper?.isEmpty == false ? whisper : nil,
                                      send: send, holds: holds(final.text, doubt: held))
        return (result, send ? held : nil)
    }

    // Why the text must not be run as it is, for TranscriptResult: what holds Return back in the app (a dangerous
    // command, the engines' doubt), whether or not this dictation was held to send.
    static func holds(_ text: String, doubt: String?) -> [String] {
        let dangerous = Config.dangerousKeywords.filter { text.localizedCaseInsensitiveContains($0) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return (dangerous.isEmpty ? [] : ["คำสั่งอันตราย: " + dangerous.joined(separator: ", ")])
            + (doubt.map { [$0] } ?? [])
    }
}
