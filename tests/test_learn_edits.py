#!/usr/bin/env python3
"""learn_edits.py on log and history lines in the formats the app and Claude Code write them."""

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(
    0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts")
)
import learn_edits

PROJECT = "/Users/me/appl/Docs/s1_design_spec"


def log(time, final):  # one dictation as VoiceAgentCLI logs it
    return (
        f'{time} file=1794390528.wav send=true engine=merged whisper_ms=925 apple="{final}" whisper="{final}" '
        f'final="{final}" starts="0" early=true pause_runs=1 server_runs=1 cli_runs=0 warm=stopped chunks=1 held=""'
    )


def sent(
    epoch, text, project=PROJECT
):  # one prompt as ~/.claude/history.jsonl stores it
    return json.dumps(
        {
            "display": text,
            "pastedContents": {},
            "timestamp": int(epoch * 1000),
            "project": project,
        },
        ensure_ascii=False,
    )


STAMP = "2026-11-11T05:20:00Z"
T0 = 1794374400  # STAMP in epoch seconds


def run(pairs, extra_sent=(), rejected=(), known=""):
    logs, history = [], list(extra_sent)
    for i, (final, text) in enumerate(pairs):
        logs.append(log(STAMP.replace("20:00", f"{20 + i}:00"), final))
        history.append(sent(T0 + 60 * i + 30, text))
    return learn_edits.proposals(
        learn_edits.dictations(logs),
        learn_edits.prompts(history),
        list(rejected),
        lambda project: known,
    )


class Proposals(unittest.TestCase):
    def test_acronym_corrected_twice_is_proposed_with_the_whole_word(self):
        got = run(
            [
                ("ตรวจ CS ให้หน่อย", "ตรวจ CIS ให้หน่อย"),
                ("ข้อมูลจาก CS ครบไหม", "ข้อมูลจาก CIS ครบไหม"),
            ]
        )
        self.assertEqual(
            got,
            [{"project": "s1_design_spec", "term": "CIS", "heard": ["CS"], "seen": 2}],
        )

    def test_one_edit_is_not_a_pattern(self):
        self.assertEqual(run([("ตรวจ CS ให้หน่อย", "ตรวจ CIS ให้หน่อย")]), [])
        self.assertEqual(run([("ส่ง CS กับ CS ให้ครบ", "ส่ง CIS กับ CIS ให้ครบ")]), [])  # twice in one dictation

    def test_each_spelling_needs_its_own_evidence(self):
        # "FOL" and "flaw" once each: proposing both would turn every spoken "flaw" into "flow".
        once = [("ครบทุก FOL นะ", "ครบทุก flow นะ"), ("ไล่ Motofun ก่อน", "ไล่ MF ก่อน"),
                ("ดู flaw นี้", "ดู flow นี้")]
        self.assertEqual(run(once), [])
        twice = once + [("ส่ง FOL ใหม่", "ส่ง flow ใหม่")]
        self.assertEqual(run(twice), [{"project": "s1_design_spec", "term": "flow", "heard": ["FOL"], "seen": 2}])

    def test_added_text_and_thai_terms_are_not_mishearings(self):
        self.assertEqual(
            run(
                [
                    ("แก้ไฟล์นี้", "แก้ไฟล์นี้ด้วย test"),
                    ("แก้ไฟล์นี้", "แก้ไฟล์นี้ด้วย test"),
                    ("พี่วิธีทำ", "มีวิธีทำ"),
                    ("พี่วิธีทำ", "มีวิธีทำ"),
                ]
            ),
            [],
        )

    def test_a_spelling_you_have_sent_as_is_is_not_proposed(self):
        pairs = [
            ("ช่วย เปิด branch", "ช่วย merge branch"),
            ("ช่วย เปิด branch", "ช่วย merge branch"),
        ]
        self.assertEqual(run(pairs, extra_sent=[sent(T0 - 3600, "เปิดไฟล์ให้หน่อย")]), [])
        # Only that project's prompts count: the correction is loaded for this project alone.
        other = sent(T0 - 3600, "เปิดไฟล์ให้หน่อย", project="/Users/me/other")
        self.assertEqual(
            [p["heard"] for p in run(pairs, extra_sent=[other])], [["เปิด"]]
        )

    def test_known_and_rejected_spellings_are_not_proposed_again(self):
        pairs = [("ตรวจ CS ให้หน่อย", "ตรวจ CIS ให้หน่อย"), ("ดู CAS ด้วย", "ดู CIS ด้วย")] * 2
        self.assertEqual(
            run(pairs, known="CIS = cs\n"),
            [{"project": "s1_design_spec", "term": "CIS", "heard": ["CAS"], "seen": 2}],
        )
        self.assertEqual(
            run(pairs, known="CIS = cs\n", rejected=[["s1_design_spec", "CIS", "CAS"]]),
            [],
        )

    def test_a_prompt_sent_before_the_dictation_or_too_late_is_not_its_edit(self):
        # The first dictation is edited in time; the second one's prompt is either side of the window, so a pattern
        # (two edits) appears only if that prompt is wrongly taken for its edit.
        logs = [log(STAMP, "ตรวจ CS ให้หน่อย"), log(STAMP.replace("20:00", "30:00"), "ข้อมูลจาก CS ครบไหม")]
        second = T0 + 600
        for moment in (second - 1, second + learn_edits.MAX_DELAY + 1):
            history = [sent(T0 + 30, "ตรวจ CIS ให้หน่อย"), sent(moment, "ข้อมูลจาก CIS ครบไหม")]
            got = learn_edits.proposals(learn_edits.dictations(logs), learn_edits.prompts(history), [], lambda _: "")
            self.assertEqual(got, [], moment - second)

    def test_two_changes_in_one_word_give_that_word_once(self):
        self.assertEqual(list(learn_edits.replacements("use the kubrnetis now", "use the kubernetes now")),
                         [("kubrnetis", "kubernetes")])

    def test_a_thai_spelling_the_app_counts_as_one_letter_is_not_proposed(self):
        # "ฟู" is one character to Swift's String.count, and the app drops one-letter spellings.
        self.assertEqual(run([("ช่วยตรวจเช็คให้ครบทุกฟูด้วยนะ", "ช่วยตรวจเช็คให้ครบทุก flow ด้วยนะ"),
                             ("ช่วยไล่ดูฟูของหน้าจอนี้ให้หน่อย", "ช่วยไล่ดู flow ของหน้าจอนี้ให้หน่อย")]), [])

    def test_a_different_prompt_sent_after_a_dictation_is_not_its_edit(self):
        # Dictated, not sent; then a prompt typed by hand that shares a word.
        self.assertEqual(run([("CS ok", "CIS architecture ok"), ("CS ok", "CIS architecture ok")]), [])

    def test_project_names_fit_the_work_file_rule(self):
        self.assertEqual(
            learn_edits.project_name("/Users/me/appl/worktree/p3.2-defect/"),
            "p3-2-defect",
        )


class Accept(unittest.TestCase):
    def test_spellings_join_the_terms_line_after_a_backup(self):
        with tempfile.TemporaryDirectory() as home:
            work, backups = os.path.join(home, "work"), os.path.join(home, "backups")
            os.makedirs(work)
            with open(
                os.path.join(work, "s1_design_spec.txt"), "w", encoding="utf-8"
            ) as f:
                f.write("# s1\nส่ง CIS ไปตรวจ\nCIS = cs\n")
            saved = learn_edits.WORK, learn_edits.learn.BACKUPS
            learn_edits.WORK, learn_edits.learn.BACKUPS = work, backups
            try:
                learn_edits.accept(
                    [
                        {
                            "project": "s1_design_spec",
                            "term": "CIS",
                            "heard": ["CAS"],
                            "seen": 2,
                        },
                        {
                            "project": "s1_design_spec",
                            "term": "flow",
                            "heard": ["FOL"],
                            "seen": 3,
                        },
                        {
                            "project": "p3-2-defect",
                            "term": "MFS",
                            "heard": ["MI-BEDS"],
                            "seen": 2,
                        },
                    ]
                )
            finally:
                learn_edits.WORK, learn_edits.learn.BACKUPS = saved
            read = lambda name: open(os.path.join(work, name), encoding="utf-8").read()
            self.assertEqual(
                read("s1_design_spec.txt"),
                "# s1\nส่ง CIS ไปตรวจ\nCIS = cs, CAS\nflow = FOL\n",
            )
            self.assertEqual(read("p3-2-defect.txt"), "MFS = MI-BEDS\n")
            self.assertEqual(len(os.listdir(backups)), 1)  # only the file that existed


class Main(unittest.TestCase):
    def test_numbers_stay_those_of_the_listing_until_the_next_one(self):
        pairs = [("ตรวจ CS ให้หน่อย", "ตรวจ CIS ให้หน่อย"), ("ข้อมูลจาก CS ครบไหม", "ข้อมูลจาก CIS ครบไหม"),
                 ("ครบทุก FOL นะ", "ครบทุก flow นะ"), ("ดู FOL นี้", "ดู flow นี้"), ("ใช้ MI-BEDS", "ใช้ MFS"),
                 ("เปิด MI-BEDS", "เปิด MFS"), ("ส่ง CAS ไป", "ส่ง CIS ไป"), ("ถาม CAS ด้วย", "ถาม CIS ด้วย")]
        logs, history = [], []
        for i, (final, text) in enumerate(pairs):
            logs.append(log(STAMP.replace("20:00", f"{20 + i}:00"), final))
            history.append(sent(T0 + 60 * i + 30, text) + "\n")
        with tempfile.TemporaryDirectory() as home:
            names = ("STATE", "HISTORY", "WORK")
            saved = [getattr(learn_edits, n) for n in names] + [learn_edits.learn.log_lines, learn_edits.learn.BACKUPS]
            learn_edits.STATE, learn_edits.HISTORY = os.path.join(home, "edits.json"), os.path.join(home, "h.jsonl")
            learn_edits.WORK, learn_edits.learn.BACKUPS = os.path.join(home, "work"), os.path.join(home, "backups")
            learn_edits.learn.log_lines = lambda: iter(logs)
            with open(learn_edits.HISTORY, "w", encoding="utf-8") as f:
                f.writelines(history)
            try:
                learn_edits.main([])
                listed = json.load(open(learn_edits.STATE, encoding="utf-8"))["listed"]
                learn_edits.main(["--reject", "3"])
                with open(learn_edits.HISTORY, "a", encoding="utf-8") as f:  # "CAS" turns out to be a real word
                    f.write(sent(T0 + 3600, "ดู CAS ของ team นี้") + "\n")
                learn_edits.main(["--accept", "1", "2"])  # CIS = CAS is stale, CIS = CS is not
                with self.assertRaises(SystemExit):
                    learn_edits.main(["--reject", "2"])  # already accepted
                learn_edits.main(["--accept", "4"])
                accepted = open(os.path.join(learn_edits.WORK, "s1_design_spec.txt"), encoding="utf-8").read()
                state = json.load(open(learn_edits.STATE, encoding="utf-8"))
                work = os.listdir(learn_edits.WORK)
            finally:
                for n, v in zip(names, saved):
                    setattr(learn_edits, n, v)
                learn_edits.learn.log_lines, learn_edits.learn.BACKUPS = saved[3], saved[4]
        self.assertEqual([(p["term"], p["heard"]) for p in listed],
                         [("CIS", ["CAS"]), ("CIS", ["CS"]), ("MFS", ["MI-BEDS"]), ("flow", ["FOL"])])
        self.assertEqual(state["rejected"], [["s1_design_spec", "MFS", "MI-BEDS"]])
        self.assertEqual(state["listed"], [None, None, None, None])
        self.assertEqual(work, ["s1_design_spec.txt"])
        self.assertEqual(accepted, "CIS = CS\nflow = FOL\n")

    def test_an_unreadable_state_file_stops_with_its_path(self):
        for content in ("{", "[]"):
            with tempfile.TemporaryDirectory() as home:
                saved, learn_edits.STATE = learn_edits.STATE, os.path.join(home, "edits.json")
                with open(learn_edits.STATE, "w", encoding="utf-8") as f:
                    f.write(content)
                try:
                    with self.assertRaises(SystemExit) as stop:
                        learn_edits.main([])
                finally:
                    learn_edits.STATE = saved
            self.assertIn("edits.json", str(stop.exception), content)

    def test_a_number_that_is_not_plain_digits_is_refused(self):
        with tempfile.TemporaryDirectory() as home:
            saved, learn_edits.STATE = learn_edits.STATE, os.path.join(home, "edits.json")
            with open(learn_edits.STATE, "w", encoding="utf-8") as f:
                json.dump({"rejected": [], "listed": [{"project": "p", "term": "CIS", "heard": ["CS"], "seen": 2}]}, f)
            try:
                for number in ("²", "٢", "1.0"):
                    with self.assertRaises(SystemExit):
                        learn_edits.main(["--reject", number])
            finally:
                learn_edits.STATE = saved


if __name__ == "__main__":
    unittest.main()
