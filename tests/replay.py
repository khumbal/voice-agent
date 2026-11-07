#!/usr/bin/env python3
"""Re-transcribes the reference recordings with Whisper as the app runs it, using the given vocabulary's prompt, merges
each with the Apple text logged for it, and scores the result against the reference reading. This is how a prompt
sentence is tried before it goes into the vocabulary: Whisper's output changes with every word of the prompt.
Usage: replay.py <harness-binary> <vocabulary.txt> [-v]   prints {"cer": ..., "looped": [...], "rows": n} as JSON
The recordings are kept in ~/.local/share/voice-agent/refs (the app's own cache drops old ones).
replay.py <harness-binary> <vocabulary.txt> --cases   the same for the kept cases (learn.py), which have no reference
reading: prints each case whose final text changes from the logged one, then {"changed": n, "rows": n}."""
import fcntl, json, os, re, struct, subprocess, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check import cer, merged, read

DATA = os.path.expanduser("~/.local/share/voice-agent")
REFS = os.path.join(DATA, "refs")
CASES = os.path.join(DATA, "cases")
CLI = next((p for p in ("/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli") if os.access(p, os.X_OK)), None)
MODEL = os.path.join(DATA, "ggml-large-v3-q5_0.bin")
VAD = os.path.join(DATA, "ggml-silero-v5.1.2.bin")
LOCK = os.path.join(DATA, "whisper.lock")  # the app's: a dictation waits for one run, not for the whole replay


def prompt_from_lines(lines):  # as Config.whisperPrompt builds it
    lines = [l.strip() for l in lines]
    return ", ".join(l for l in lines if l and not l.startswith("#") and " = " not in l)


def prompt(vocabulary):
    return prompt_from_lines(open(vocabulary, encoding="utf-8").read().splitlines())


# whisper.cpp keeps only a prompt's last n_text_ctx/2 tokens and drops the rest without a word: past this the first
# sentences teach Whisper nothing (whisper-cli's "prompt" runs stop at 227, the 224 plus its 3 special tokens).
PROMPT_TOKENS = 224
_WORD = re.compile(rb"'s|'t|'re|'ve|'m|'ll|'d| ?[A-Za-z]+| ?[0-9]+| ?[^\sA-Za-z0-9]+|\s+(?!\S)|\s+")
_model_words = None


def prompt_tokens(text_prompt):
    """The prompt's tokens as whisper.cpp counts them: its own vocabulary, read from the model file; the words its
    regex splits off (in the C locale Thai bytes are not letters); then the longest entry at each position. Matches
    whisper-cli's prompt runs on the reference recordings. 0 without the model: no Whisper, no prompt to fit."""
    global _model_words
    if _model_words is None:
        if not os.path.exists(MODEL):
            return 0
        with open(MODEL, "rb") as f:  # ggml: magic, 11 hparams, mel filters, then the vocabulary
            f.read(4 * 12)
            n_mel, n_fft = struct.unpack("<ii", f.read(8))
            f.read(4 * n_mel * n_fft)
            _model_words = {f.read(struct.unpack("<I", f.read(4))[0])
                            for _ in range(struct.unpack("<i", f.read(4))[0])}
    longest, count = max(map(len, _model_words)), 0
    for word in _WORD.findall((" " + text_prompt).encode()):  # whisper.cpp tokenizes it after a space
        i = 0
        while i < len(word):
            j = min(len(word), i + longest)
            while j > i + 1 and word[i:j] not in _model_words:
                j -= 1
            count, i = count + 1, j
    return count


def whisper(wav, text_prompt):  # the app's arguments (transcribeWithWhisper)
    args = [CLI, "-m", MODEL, "-f", wav, "-l", "th", "-nt", "-np", "-sns", "-bs", "1", "-bo", "1", "--prompt",
            text_prompt]
    if os.path.exists(VAD):
        args += ["--vad", "-vm", VAD, "-vp", "200"]
    with open(LOCK, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        out = subprocess.run(args, capture_output=True, text=True, timeout=120).stdout
    return " ".join(l.strip() for l in out.splitlines() if l.strip())


def looped(text):  # a phrase three times in a row, the way a prompt that is too long makes Whisper repeat
    return bool(re.search(r"(.{6,}?)\1{2,}", text.replace(" ", "")))


def replay(binary, vocabulary, verbose=False):
    if not CLI or not os.path.exists(MODEL):
        raise SystemExit("replay: whisper-cli or the model is missing")
    text_prompt = prompt(vocabulary)
    rows = {}
    for g in read("merge_golden.tsv"):
        wav = os.path.join(REFS, g["name"].removeprefix("log ") + ".wav")
        if g["reference"] and g["name"].startswith("log ") and os.path.exists(wav):
            rows[g["name"]] = (g, whisper(wav, text_prompt))
    if not rows:
        raise SystemExit("replay: no reference recordings matched the test data")
    out = merged(binary, {name: (g["apple"], text) for name, (g, text) in rows.items()})
    if verbose:
        for name, (g, text) in rows.items():
            print(f"{name} {cer(g['reference'], out[name]):.3f} | {out[name]}", file=sys.stderr)
    return {"cer": sum(cer(g["reference"], out[name]) for name, (g, _) in rows.items()) / max(len(rows), 1),
            "looped": [name for name, (_, text) in rows.items() if looped(text)], "rows": len(rows)}


def replay_cases(binary, vocabulary):
    if not CLI or not os.path.exists(MODEL):
        raise SystemExit("replay: whisper-cli or the model is missing")
    path = os.path.join(CASES, "cases.tsv")
    if not os.path.exists(path):
        raise SystemExit(f"replay: no cases yet ({path}): learn.py --cases keeps them")
    with open(path, encoding="utf-8") as f:
        header, *lines = [line.rstrip("\n").split("\t") for line in f if line.strip()]
    text_prompt = prompt(vocabulary)
    rows = {}
    for case in (dict(zip(header, line)) for line in lines):
        wav = os.path.join(CASES, case["name"].removeprefix("log ") + ".wav")
        if os.path.exists(wav):
            rows[case["name"]] = (case, whisper(wav, text_prompt))
    out = merged(binary, {name: (case["apple"], text) for name, (case, text) in rows.items()})
    changed = [name for name, (case, _) in rows.items() if out[name] != case["final"]]
    for name in changed:
        case = rows[name][0]
        print(f"{name} ({case['why'] or 'feedback'}){' said: ' + case['said'] if case['said'] else ''}\n"
              f"  then: {case['final']}\n  now:  {out[name]}", file=sys.stderr)
    return {"changed": len(changed), "rows": len(rows)}


if __name__ == "__main__":
    if "--cases" in sys.argv[3:]:
        print(json.dumps(replay_cases(sys.argv[1], sys.argv[2])))
    else:
        print(json.dumps(replay(sys.argv[1], sys.argv[2], "-v" in sys.argv[3:])))
