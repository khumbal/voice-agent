#!/usr/bin/env python3
"""Extract Config and the transcript functions from the app source into a stdin harness, so tests run the shipped
code, not a copy. It reads the vocabulary file given here instead of the user's ~/.config copy.
Input lines: merge<TAB>name<TAB>apple<TAB>whisper (as finishAndDispatch combines them), correct<TAB>name<TAB>text
start<TAB>name<TAB>current<TAB>segment (startChange; "none" for nil), runstart<TAB>name<TAB>frames<TAB>chunk starts
or endchunks<TAB>name<TAB>run start<TAB>chunk starts<TAB>texts (lists comma-separated, a text "-" for nil; prints
start|texts), doubt<TAB>name<TAB>apple<TAB>whisper<TAB>silenced ("-": it failed; the final text is made as merge
makes it; silenced "yes" when the speaker gate silenced another voice; prints "send" for nil), mic<TAB>name<TAB>devices<TAB>preferred (Microphone.chosen; devices
"name/transport fourcc[/default];…", the transport "0" when unreadable, preferred "name;…"; prints the chosen name
or "none"), gate<TAB>name<TAB>seconds<TAB>window scores (Config.speakerWindows of a run that long; a score "-" for a
quiet window; prints the silenced ranges in seconds or "none"), voiced<TAB>name<TAB>frames (one 100 ms frame each,
"1" at -20 dB, "q" -45 dB, "r" -55 dB, "0" -60 dB; prints Config.isVoiced).
Output lines: name<TAB>result. Usage: mkharness.py <app.swift> <vocabulary.txt> <out.swift>"""
import json, sys

source, vocabulary, out = sys.argv[1:4]
src = open(source, encoding="utf-8").read().split("\n")
home_path = 'NSHomeDirectory() + "/.config/voice-agent/vocabulary.txt"'
config_end = next(i for i, l in enumerate(src) if l.startswith("enum TargetMode"))  # Microphone, after Config, too
config = "\n".join(src[src.index("struct Config {"):config_end])
if config.count(home_path) != 1:
    sys.exit(f"mkharness: expected one {home_path} in Config")
config = config.replace(home_path, json.dumps(vocabulary))
start = next(i for i, l in enumerate(src) if "private func runStart" in l)
end = next(i for i, l in enumerate(src) if "private func pruneRecordings" in l)
funcs = "\n".join(src[start:end]).replace("    private func ", "    func ")
main = r'''
let m = M()
while let line = readLine() {
    let p = line.components(separatedBy: "\t")
    switch (p.first, p.count) {
    case ("merge", 4):
        print("\(p[1])\t\(m.finalText(apple: p[2], whisper: m.collapseRepeats(p[3])).text)")
    case ("correct", 3):
        print("\(p[1])\t\(Config.corrected(p[2]))")
    case ("start", 4):
        print("\(p[1])\t\(m.startChange(from: p[2], to: p[3]) ?? "none")")
    case ("runstart", 4):
        print("\(p[1])\t\(m.runStart(upTo: Int(p[2])!, chunkStarts: p[3].split(separator: ",").map { Int($0)! }))")
    case ("doubt", 5):
        let whisper = p[3] == "-" ? nil : m.collapseRepeats(p[3])
        let final = m.finalText(apple: p[2], whisper: whisper?.isEmpty == false ? whisper : nil)
        print("\(p[1])\t\(m.doubt(apple: p[2], whisper: whisper, final: final, silenced: p[4] == "yes") ?? "send")")
    case ("endchunks", 5):
        let texts = p[4].split(separator: ",", omittingEmptySubsequences: false).map { $0 == "-" ? nil : String($0) }
        let end = m.endChunks(texts, chunkStarts: p[3].split(separator: ",").map { Int($0)! }, runStart: Int(p[2])!)
        print("\(p[1])\t\(end.start)|\(end.texts.joined(separator: ","))")
    case ("gate", 4):
        let count = Int(Double(p[2])! * 16000), starts = Config.speakerWindows(count: count)
        let scores = p[3].split(separator: ",").map { $0 == "-" ? nil : Float($0)! }
        guard scores.count == starts.count else { print("\(p[1])\t\(starts.count) windows"); continue }
        let ranges = Config.silencedRanges(count: count, starts: starts, scores: scores)
            .map { String(format: "%.1f-%.1f", Double($0.lowerBound) / 16000, Double($0.upperBound) / 16000) }
        print("\(p[1])\t\(ranges.isEmpty ? "none" : ranges.joined(separator: ","))")
    case ("voiced", 3):
        // After a loud frame, so the window starts mid-array as a run's windows do.
        let levels: [Character: Float] = ["1": 0.1, "0": 0.001, "q": 0.0056, "r": 0.0018]
        let frames = p[2].flatMap { [Float](repeating: levels[$0]!, count: 1600) }
        let samples = [Float](repeating: 0.1, count: 1600) + frames
        print("\(p[1])\t\(Config.isVoiced(samples[1600...]))")
    case ("mic", 4):
        let microphones = p[2].split(separator: ";").enumerated().map { i, device -> Microphone in
            let f = device.split(separator: "/").map(String.init)
            let code = f[1] == "0" ? 0 : f[1].padding(toLength: 4, withPad: " ", startingAt: 0).utf8
                .reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return Microphone(id: AudioDeviceID(i), name: f[0], transport: code, isDefault: f.count > 2)
        }
        let preferred = p[3].split(separator: ";").map(String.init)
        print("\(p[1])\t\(Microphone.chosen(from: microphones, preferred: preferred)?.name ?? "none")")
    default:
        print("\(p.count > 1 ? p[1] : "?")\tBAD INPUT LINE")
    }
}
'''
open(out, "w", encoding="utf-8").write(
    "import Foundation\nimport CoreAudio\nimport NaturalLanguage\n"
    + config + "\nstruct M {\n" + funcs + "\n}\n" + main)
