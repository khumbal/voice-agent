#!/usr/bin/env python3
"""Runs the harness on the test tables and compares.
- corrections.tsv (name, input, expected): fixed answers; any difference fails.
- starts.tsv (name, current, segment, expected): how a change of the recognizer's start is read (startChange), on
  pairs from the log labelled by what was said (the Whisper text of the same recording), except where the name
  says the rule cannot tell, plus the half-length boundary; any difference fails.
- merge_golden.tsv (name, apple, whisper, reference, expected): the merge's current output on real engine pairs. A
  change fails until reviewed and accepted with --update; the character error rate against the reference reading (my
  transcription of the recording, blank when none) is printed so the review can see whether the change helped.
- chunks.tsv (name, check, at, chunk_starts, texts, expected): where a Whisper run starts in a chunked recording
  (runStart, at = frames heard) and which closed chunks' texts the end uses (endChunks, at = the run's start).
- doubts.tsv (name, apple, whisper, silenced, expected): why a held-to-send dictation is typed without Return ("send":
  it is sent), its final text made as the app makes it; whisper "-" when it failed; silenced "yes" when the speaker
  gate silenced another voice in the recording.
- mics.tsv (name, devices, preferred, expected): which input a recording uses (Microphone.chosen), devices as
  "name/transport fourcc (0: unreadable)[/default];…" in CoreAudio's order, preferred as microphones.txt lists
  them ("name;…").
- gates.tsv (name, seconds, at, scores, expected): which parts of a run (starting `at` seconds into the recording) the
  speaker gate silences (Config.silencedRanges) from its window scores, one per Config.speakerWindows window ("-":
  quiet, not scored), as "from-to" seconds.
- results.tsv (name, apple, whisper, send, silenced, seconds, expected): the JSON a done recording hands to other
  programs (TranscriptResult) with its holds, then "|" and the doubt that holds Return ("send": none), made from the
  engines' texts as the app makes them; whisper "-" when it failed, "~" when it is not installed. The doubt is a hold
  whether or not it was a send.
- voiced.tsv (name, frames, expected): whether a window (1.5 s in the app) is scored (Config.isVoiced), then "|" and
  whether the same samples, as the recording's end after its last pause, are silence (Config.isSilent), one
  character per 100 ms frame: "1" -20 dB, "q" -45 dB, "r" -55 dB (either side of Config.speakerQuietDB), "0" -60 dB,
  "h" half a frame at -48 dB (-51 dB if taken as a whole frame), "n" a frame that is not a number.
Usage: check.py <harness-binary> [--update]"""
import os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))


def read(name):  # tab-separated, header row, no quoting: dictation text never holds a tab or newline
    with open(os.path.join(HERE, name), encoding="utf-8") as f:
        header, *rows = [line.rstrip("\n").split("\t") for line in f if line.strip()]
    return [dict(zip(header, row)) for row in rows]


def run(binary, lines):
    out = subprocess.run([binary], input="".join(l + "\n" for l in lines), capture_output=True, text=True, check=True)
    return dict(line.split("\t", 1) for line in out.stdout.splitlines())


def corrected(binary, rows):  # rows: name -> text
    return run(binary, (f"correct\t{name}\t{text}" for name, text in rows.items()))


def merged(binary, rows):  # rows: name -> (apple, whisper)
    return run(binary, (f"merge\t{name}\t{apple}\t{whisper}" for name, (apple, whisper) in rows.items()))


def cer(ref, hyp):
    ref, hyp = ref.replace(" ", ""), hyp.replace(" ", "")
    row = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        prev, row[0] = row[0], i
        for j, h in enumerate(hyp, 1):
            prev, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, prev + (r != h))
    return row[-1] / max(len(ref), 1)


def correction_failures(binary):
    cases = read("corrections.tsv")
    got = corrected(binary, {c["name"]: c["input"] for c in cases})
    return [(c, got[c["name"]]) for c in cases if got[c["name"]] != c["expected"]]


def start_failures(binary):
    cases = read("starts.tsv")
    got = run(binary, (f"start\t{c['name']}\t{c['current']}\t{c['segment']}" for c in cases))
    return [(c, got[c["name"]]) for c in cases if got[c["name"]] != c["expected"]]


def chunk_failures(binary):
    cases = read("chunks.tsv")
    got = run(binary, ("\t".join([c["check"], c["name"], c["at"], c["chunk_starts"]]
                                 + ([c["texts"]] if c["check"] == "endchunks" else [])) for c in cases))
    return [(c, got[c["name"]]) for c in cases if got[c["name"]] != c["expected"]]


def doubt_failures(binary):
    cases = read("doubts.tsv")
    got = run(binary, (f"doubt\t{c['name']}\t{c['apple']}\t{c['whisper']}\t{c['silenced']}" for c in cases))
    return [(c, got[c["name"]]) for c in cases if got[c["name"]] != c["expected"]]


def mic_failures(binary):
    cases = read("mics.tsv")
    got = run(binary, (f"mic\t{c['name']}\t{c['devices']}\t{c['preferred']}" for c in cases))
    return [(c, got[c["name"]]) for c in cases if got[c["name"]] != c["expected"]]


def gate_failures(binary):
    cases = read("gates.tsv")
    got = run(binary, (f"gate\t{c['name']}\t{c['seconds']}\t{c['at']}\t{c['scores']}" for c in cases))
    return [(c, got[c["name"]]) for c in cases if got[c["name"]] != c["expected"]]


def voiced_failures(binary):
    cases = read("voiced.tsv")
    got = run(binary, (f"voiced\t{c['name']}\t{c['frames']}" for c in cases))
    return [(c, got[c["name"]]) for c in cases if got[c["name"]] != c["expected"]]


def result_failures(binary):
    cases = read("results.tsv")
    fields = ["name", "apple", "whisper", "send", "silenced", "seconds"]
    got = run(binary, ("\t".join(["result"] + [c[f] for f in fields]) for c in cases))
    return [(c, got[c["name"]]) for c in cases if got[c["name"]] != c["expected"]]


def reference_cer(golden, outputs):  # mean over the rows that have a reference reading
    scored = [g for g in golden if g["reference"]]
    return sum(cer(g["reference"], outputs[g["name"]]) for g in scored) / len(scored)


def main():
    binary, update = sys.argv[1], "--update" in sys.argv[2:]
    failures = correction_failures(binary)
    for c, got in failures:
        print(f"FAIL correct {c['name']}\n  got  {got}\n  want {c['expected']}")
    starts = start_failures(binary)
    for c, got in starts:
        print(f"FAIL start {c['name']}: {c['current']} -> {c['segment']}\n  got  {got}\n  want {c['expected']}")
    chunks = chunk_failures(binary)
    for c, got in chunks:
        print(f"FAIL chunks {c['name']}\n  got  {got}\n  want {c['expected']}")
    doubts = doubt_failures(binary)
    for c, got in doubts:
        print(f"FAIL doubt {c['name']}\n  got  {got}\n  want {c['expected']}")
    mics = mic_failures(binary)
    for c, got in mics:
        print(f"FAIL mic {c['name']}\n  got  {got}\n  want {c['expected']}")

    gates = gate_failures(binary)
    for c, got in gates:
        print(f"FAIL gate {c['name']}\n  got  {got}\n  want {c['expected']}")

    voiced = voiced_failures(binary)
    for c, got in voiced:
        print(f"FAIL voiced {c['name']}\n  got  {got}\n  want {c['expected']}")

    results = result_failures(binary)
    for c, got in results:
        print(f"FAIL result {c['name']}\n  got  {got}\n  want {c['expected']}")

    golden = read("merge_golden.tsv")
    got = merged(binary, {g["name"]: (g["apple"], g["whisper"]) for g in golden})
    changed = [g for g in golden if got[g["name"]] != g["expected"]]
    for g in changed:
        ref = g["reference"]
        score = f" cer {cer(ref, g['expected']):.3f} -> {cer(ref, got[g['name']]):.3f}" if ref else ""
        print(f"{'UPDATE' if update else 'CHANGED'} merge {g['name']}{score}"
              f"\n  was {g['expected']}\n  now {got[g['name']]}")
    print(f"merge cer on {sum(1 for g in golden if g['reference'])} references:"
          f" apple {reference_cer(golden, {g['name']: g['apple'] for g in golden}):.4f}"
          f" whisper {reference_cer(golden, {g['name']: g['whisper'] for g in golden}):.4f}"
          f" merged {reference_cer(golden, got):.4f}")

    failed = (len(failures) + len(starts) + len(chunks) + len(doubts) + len(mics) + len(gates) + len(voiced)
              + len(results))
    if update and changed:
        for g in golden:
            g["expected"] = got[g["name"]]
        with open(os.path.join(HERE, "merge_golden.tsv"), "w", encoding="utf-8") as f:
            f.writelines("\t".join(row) + "\n" for row in [list(golden[0])] + [list(g.values()) for g in golden])
    elif changed:
        failed += len(changed)
    verdict = "ok" if not failed else f"{failed} failed"
    print(f"corrections {len(read('corrections.tsv'))}, starts {len(read('starts.tsv'))}, "
          f"chunks {len(read('chunks.tsv'))}, doubts {len(read('doubts.tsv'))}, mics {len(read('mics.tsv'))}, "
          f"gates {len(read('gates.tsv'))}, voiced {len(read('voiced.tsv'))}, results {len(read('results.tsv'))}, "
          f"merge {len(golden)}: {verdict}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
