#!/usr/bin/env python3
"""Learns per-project corrections from the edits you make to dictated text before sending it, without leaving this Mac.

Each dictation's final text (~/Library/Logs/voice-agent.log) is paired with the prompt Claude Code recorded when you
sent it (~/.claude/history.jsonl: the text as sent and the project it was sent in). A span you replaced becomes a
`term = heard` candidate for that project, kept only when the term holds an English letter (technical terms,
acronyms, names: what the engines mishear and a correction can fix) and that spelling was corrected to that term
in at least MIN_SEEN dictations. Text you only added or removed is new content, not a mishearing.

Nothing is written until you accept: listing saves the numbered proposals, --accept writes the chosen ones to
~/.config/voice-agent/work/<project>.txt (after a backup), --reject keeps them from coming back.
Usage: learn_edits.py [--accept N ...] [--reject N ...]"""

import calendar
import difflib
import json
import os
import re
import shutil
import sys
import time
import unicodedata

import learn

HISTORY = os.path.join(learn.HOME, ".claude/history.jsonl")
WORK = os.path.join(learn.HOME, ".config/voice-agent/work")
STATE = os.path.join(learn.LEARN, "edits.json")
MIN_SEEN = (
    2  # one edit may be a slip or a change of mind; the same one twice is a pattern
)
MAX_DELAY = 600  # seconds from the dictation to the send: the edit, then Enter
MIN_SIMILARITY = (
    0.6  # below this the sent prompt is another text, not an edit of the dictation
)
MAX_WORDS, MAX_CHARS = 3, 30  # a longer replacement is rewording, not a misheard term
NEAR = 2  # changes this close (in characters) are one replacement: "side Tommee" -> "assign to me"
LATIN_LETTER = re.compile(r"[A-Za-z]")
WORD_CHAR = re.compile(r"[A-Za-z0-9]")


def project_name(path):
    """The work file name for a project directory, in the characters the app accepts for one."""
    return re.sub(r"[^A-Za-z0-9_-]", "-", os.path.basename(path.rstrip("/")))


def dictations(lines):
    """(epoch seconds, final text) of each logged dictation."""
    for line in lines:
        m = learn.ENTRY.match(line)
        if m:
            yield calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%SZ")), m.group(6)


def prompts(lines):
    """(epoch seconds, text, project) of each prompt sent to Claude Code."""
    for line in lines:
        try:
            entry = json.loads(line)
            yield entry["timestamp"] / 1000, entry["display"], entry["project"]
        except (ValueError, KeyError, TypeError):
            continue


def similarity(a, b):  # autojunk off, as in replacements: past 200 characters it ignores the most common ones
    return difflib.SequenceMatcher(None, a, b, autojunk=False).ratio()


def pairs(spoken, sent):
    """(final text, sent text, project) for each dictation whose text was sent after an edit."""
    sent = sorted(sent)
    used = set()
    for moment, final in spoken:
        candidates = [
            i
            for i, (t, _, _) in enumerate(sent)
            if i not in used and 0 <= t - moment <= MAX_DELAY
        ]
        if not candidates:
            continue
        best = max(
            candidates,
            key=lambda i: similarity(final, sent[i][1]),
        )
        if similarity(final, sent[best][1]) < MIN_SIMILARITY:
            continue
        used.add(best)
        if final.strip() != sent[best][1].strip():
            yield final, sent[best][1], sent[best][2]


def replacements(final, sent):
    """(heard, term) for each span of the final text that the sent text replaced."""
    ops = [
        op
        for op in difflib.SequenceMatcher(
            None, final, sent, autojunk=False
        ).get_opcodes()
        if op[0] != "equal"
    ]
    spans = []
    for _, a1, a2, b1, b2 in ops:
        # Equal text surrounds the change, so widening both sides by the same characters keeps them aligned: a
        # change inside an English word takes the whole word ("CS" -> "CIS", not "" -> "I"). Widening that runs into
        # the next change misaligns the sides there, but then the two overlap and become one span, which keeps only
        # the first change's start and the last one's end.
        while a1 > 0 and b1 > 0 and WORD_CHAR.match(final[a1 - 1]):
            a1, b1 = a1 - 1, b1 - 1
        while a2 < len(final) and b2 < len(sent) and WORD_CHAR.match(final[a2]):
            a2, b2 = a2 + 1, b2 + 1
        if spans and a1 - spans[-1][1] <= NEAR:
            spans[-1] = (spans[-1][0], a2, spans[-1][2], b2)
        else:
            spans.append((a1, a2, b1, b2))
    for a1, a2, b1, b2 in spans:
        yield final[a1:a2].strip(), sent[b1:b2].strip()


def letters(text):
    """Characters as the app's String.count counts them: a Thai vowel or tone mark joins its consonant."""
    return sum(1 for c in text if unicodedata.category(c) not in ("Mn", "Mc") and c != "\u0e33")


def is_mishearing(heard, term):
    if letters(heard) < 2 or not LATIN_LETTER.search(term) or heard.lower() == term.lower():
        return False  # the app drops one-letter spellings; a Thai-only term is not what this learns
    if heard in term or term in heard:
        return False  # text added to or cut from what was heard
    return all(
        len(s.split()) <= MAX_WORDS and len(s) <= MAX_CHARS for s in (heard, term)
    )


def occurs(heard, text):
    """Whether the app's correction for `heard` would match in `text`, as Config.corrections builds it: English whole
    words in any case, Thai anywhere (the app also wants a word edge there, so this drops a few more), a space also
    matching none."""
    pattern = r"\s*".join(re.escape(part) for part in heard.split(" "))
    if heard.isascii():
        pattern = rf"(?<![A-Za-z0-9]){pattern}(?![A-Za-z0-9])"
    return re.search(pattern, text, re.IGNORECASE) is not None


def proposals(spoken, sent, rejected, known):
    """[{project, term, heard: [spelling], seen}], most seen first: a spelling you corrected to the same term in
    MIN_SEEN dictations of a project, unless it is already in that term's line, rejected, or found in a prompt you
    sent in that project: the app would rewrite that word wherever it is said ("เปิด" -> "merge"). Each spelling needs
    its own evidence: "FOL" and "flaw" corrected to "flow" once each would make every spoken "flaw" a "flow".
    `known(project)` is the text of that project's work file."""
    sent = list(sent)
    kept = {}
    for _, text, project in sent:
        kept.setdefault(project_name(project), []).append(text)
    seen = {}
    for final, text, project in pairs(spoken, sent):
        keys = {(project_name(project), term, heard) for heard, term in replacements(final, text)
                if is_mishearing(heard, term)}
        for key in keys:
            seen[key] = seen.get(key, 0) + 1
    found = []
    for (project, term, heard), count in seen.items():
        line = next((l for l in learn.vocabulary_lines(known(project)) if l.startswith(term + " = ")), "")
        present = {s.strip().lower() for s in line.partition(" = ")[2].split(",")}
        if (count >= MIN_SEEN and heard.lower() not in present and [project, term, heard] not in rejected
                and not any(occurs(heard, t) for t in kept.get(project, []))):
            found.append({"project": project, "term": term, "heard": [heard], "seen": count})
    return sorted(found, key=lambda p: (-p["seen"], p["project"], p["term"], p["heard"]))


def current(rejected):
    """The proposals the log and history support now."""
    history = open(HISTORY, encoding="utf-8").readlines() if os.path.exists(HISTORY) else []
    return proposals(dictations(learn.log_lines()), prompts(history), rejected, known_text)


def known_text(project):
    path = os.path.join(WORK, project + ".txt")
    return open(path, encoding="utf-8").read() if os.path.exists(path) else ""


def accept(chosen):
    for project in sorted({p["project"] for p in chosen}):
        path = os.path.join(WORK, project + ".txt")
        lines = (
            known_text(project).rstrip("\n").split("\n") if os.path.exists(path) else []
        )
        for p in (p for p in chosen if p["project"] == project):
            lines = learn.with_correction(lines, p["term"], p["heard"])
        os.makedirs(WORK, exist_ok=True)
        if os.path.exists(path):
            os.makedirs(learn.BACKUPS, exist_ok=True)
            stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
            shutil.copy2(
                path, os.path.join(learn.BACKUPS, f"work-{project}-{stamp}.txt")
            )
        with open(path + ".tmp", "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        os.replace(path + ".tmp", path)
        print(
            f"{path}: "
            + "; ".join(
                f"{p['term']} = {', '.join(p['heard'])}"
                for p in chosen
                if p["project"] == project
            )
        )


def main(argv):
    try:
        with open(STATE, encoding="utf-8") as f:
            state = json.load(f)
    except FileNotFoundError:
        state = {}
    except (OSError, ValueError) as error:
        sys.exit(f"{STATE} is unreadable ({error}): fix or delete it")
    if not isinstance(state, dict):
        sys.exit(f"{STATE} is not a JSON object: fix or delete it")
    rejected, listed = state.get("rejected", []), state.get("listed", [])
    action = argv[0] if argv else ""
    if action in ("--accept", "--reject"):
        numbers = {int(n) for n in argv[1:] if n.isdecimal() and n.isascii()}
        chosen = [p for i, p in enumerate(listed, 1) if i in numbers and p]
        if (
            not argv[1:]
            or len(numbers) != len(set(argv[1:]))
            or len(chosen) != len(numbers)
        ):
            sys.exit(
                f"numbers from the last listing not yet accepted or rejected, 1-{len(listed)}: {' '.join(argv[1:])}"
            )
        if action == "--accept":
            # Checked again: since the listing a prompt may have used the spelling as a real word.
            still = {(p["project"], p["term"], tuple(p["heard"])) for p in current(rejected)}
            stale = [p for p in chosen if (p["project"], p["term"], tuple(p["heard"])) not in still]
            for p in stale:
                print(f"skipped, no longer supported: [{p['project']}] {p['term']} = {', '.join(p['heard'])}")
            accept([p for p in chosen if p not in stale])
        else:
            rejected += [
                [p["project"], p["term"], h] for p in chosen for h in p["heard"]
            ]
        listed = [None if p in chosen else p for p in listed]  # the numbers you see stay valid until the next listing
    elif argv:
        sys.exit(__doc__)
    else:
        listed = current(rejected)
        for i, p in enumerate(listed, 1):
            print(
                f"{i}. [{p['project']}] {p['term']} = {', '.join(p['heard'])}   (edited {p['seen']} times)"
            )
        print(
            f"{len(listed)} proposals"
            + (": --accept or --reject by number" if listed else "")
        )
    os.makedirs(learn.LEARN, exist_ok=True)
    with open(STATE + ".tmp", "w", encoding="utf-8") as f:
        json.dump(
            {"rejected": rejected, "listed": listed}, f, ensure_ascii=False, indent=1
        )
    os.replace(STATE + ".tmp", STATE)


if __name__ == "__main__":
    main(sys.argv[1:])
