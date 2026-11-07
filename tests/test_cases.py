#!/usr/bin/env python3
"""Which recordings learn.py keeps as cases: on a log in the app's format, with the cache, feedback and vocabulary in a
temporary directory. Usage: test_cases.py (exits non-zero on a failure)."""
import os, sys, tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))
import learn  # noqa: E402


def entry(time, file, apple, whisper, final, engine="merged"):  # as finishAndDispatch logs it
    return (f'{time} file={file}.wav send=true engine={engine} whisper_ms=1200 apple="{apple}" whisper="{whisper}" '
            f'final="{final}" starts="" early=true pause_runs=1 server_runs=1 cli_runs=0\n')


def main():
    failures = []

    def expect(label, got, want):
        if got != want:
            failures.append(f"{label}: got {got!r}, want {want!r}")

    with tempfile.TemporaryDirectory() as tmp:
        learn.LOG = os.path.join(tmp, "voice-agent.log")
        learn.RECORDINGS = os.path.join(tmp, "cache")
        learn.CASES = os.path.join(tmp, "cases")
        learn.FEEDBACK = os.path.join(tmp, "feedback.txt")
        learn.VOCABULARY = os.path.join(tmp, "vocabulary.txt")
        os.makedirs(learn.RECORDINGS)
        open(learn.VOCABULARY, "w", encoding="utf-8").write("ช่วย run test ให้หน่อย\n")
        for f in ("1001", "1002", "1003", "1005"):  # 1004 has been dropped from the cache
            open(os.path.join(learn.RECORDINGS, f + ".wav"), "wb").write(b"RIFF" + f.encode())
        agree = "ช่วยตรวจสอบข้อมูลให้หน่อยนะครับ"
        with open(learn.LOG, "w", encoding="utf-8") as log:
            # The oldest, so the limit below would take it first if feedback did not keep it.
            log.write(entry("2026-10-20T09:59:00Z", "1003", "เช็คทุกฟูด้วยนะ", "เช็คทุกฟูด้วยนะ", "เช็คทุกฟูด้วยนะ"))
            log.write(entry("2026-10-20T10:00:00Z", "1001", agree, agree, agree))  # nothing wrong
            log.write(entry("2026-10-20T10:01:00Z", "1002", agree, "", agree, engine="apple"))  # Whisper failed: 3
            log.write(entry("2026-10-20T10:03:00Z", "1004", agree, "", agree, engine="apple"))

        state, added = learn.harvest_cases({})
        cases = learn.read_cases()
        expect("kept: only the suspicious entry whose recording is still cached", sorted(cases), ["log 1002"])
        expect("added", added, 1)
        expect("its recording is copied", os.path.exists(os.path.join(learn.CASES, "1002.wav")), True)
        expect("its reasons", cases["log 1002"]["points"], "3")
        expect("cursor", state["last_case"], "2026-10-20T10:03:00Z")

        # A feedback line names an earlier, unsuspicious entry: kept with what was said, cursor or not.
        # A heard side too short to point anywhere ("ฟู" is in many) is ignored; the newest match is the one meant.
        open(learn.FEEDBACK, "w", encoding="utf-8").write("ฟู -> flow\nทุกฟู -> ทุก flow\n")
        state, added = learn.harvest_cases(state)
        cases = learn.read_cases()
        expect("after feedback", sorted(cases), ["log 1002", "log 1003"])
        expect("what was said", cases["log 1003"]["said"], "ทุกฟู -> ทุก flow")
        state, added = learn.harvest_cases(state)
        expect("a second run adds nothing", added, 0)
        # A feedback line already used does not pick up later dictations that happen to hold the same words.
        open(os.path.join(learn.RECORDINGS, "1006.wav"), "wb").write(b"RIFF1006")
        with open(learn.LOG, "a", encoding="utf-8") as log:
            log.write(entry("2026-10-20T10:04:00Z", "1006", "ทุกฟูโอเค", "ทุกฟูโอเค", "ทุกฟูโอเค"))
        state, added = learn.harvest_cases(state)
        expect("a used feedback line keeps nothing new", added, 0)

        # Over the limit the oldest without feedback goes.
        with open(learn.LOG, "a", encoding="utf-8") as log:
            log.write(entry("2026-10-20T10:05:00Z", "1005", agree, "", agree, engine="apple"))
        learn.MAX_CASES = 2
        state, added = learn.harvest_cases(state)
        cases = learn.read_cases()
        expect("pruned to the limit, feedback case kept", sorted(cases), ["log 1003", "log 1005"])
        expect("pruned recording removed", os.path.exists(os.path.join(learn.CASES, "1002.wav")), False)
        state, added = learn.harvest_cases(state)
        expect("a pruned case does not come back from the cache", added, 0)

    for f in failures:
        print("FAIL", f)
    print(f"cases: {'ok' if not failures else f'{len(failures)} failed'}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
