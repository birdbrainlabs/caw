#!/usr/bin/env python3
"""
Reads corpus.jsonl and answers the question the corpus was built to answer:
are the remaining errors acoustic or contextual?

The distinction decides what to build next. An acoustic error is the recognizer
mishearing a sound — "spear" as "spare", "Mak" as "mock". Those are fixed by
telling the recognizer what words to expect (contextualStrings) or, eventually,
by a better speech model. A contextual error is the recognizer hearing correctly
and the sentence still being wrong — a missing sentence break, a filler the
cleaner left in. Those are fixed by a better cleanup pass. Reasoning cannot tell
these apart; counting them can.

Every edit in the corpus is diffed at word level and sorted into a bucket. The
report ends with the two lists worth acting on immediately: words the recognizer
keeps getting wrong, and cleanup the deterministic pass is already missing.

    Scripts/corpus-report.py                 # the report
    Scripts/corpus-report.py --vocab         # just the vocabulary candidates
    Scripts/corpus-report.py --examples 8    # more worked examples per bucket
    Scripts/corpus-report.py --file path     # a corpus from somewhere else

Nothing here writes, and nothing leaves the machine.
"""

import argparse
import difflib
import json
import os
import re
import sys
from collections import Counter, defaultdict

DEFAULT_CORPUS = os.path.expanduser(
    "~/Library/Application Support/VoiceApp/corpus.jsonl"
)

# Fillers the deterministic cleaner is meant to remove. If the user is still
# deleting these by hand, the cleaner has a gap and the fix is a rule, not a model.
FILLERS = {
    "um", "uh", "erm", "ah", "eh", "hmm", "mm", "mhm", "like", "yeah",
    "okay", "ok", "so", "well", "right", "anyway", "basically", "actually",
    "literally", "you know", "i mean", "sort of", "kind of",
}

WORD = re.compile(r"\w+(?:['’]\w+)*|[^\w\s]")
ALPHA = re.compile(r"[^a-z]")


def tokenize(text):
    return WORD.findall(text or "")


def is_punct(token):
    return not any(c.isalnum() for c in token)


def bare(token):
    """A word reduced to comparable letters: case, apostrophes and marks gone."""
    return ALPHA.sub("", token.lower().replace("’", "").replace("'", ""))


def soundex(word):
    """
    Soundex, the crude version, used only to ask "could these two have sounded
    alike to a recognizer?" It over-matches, which is the safe direction here —
    a pair it wrongly calls acoustic still gets shown in the substitution list
    where a human can see it is not.
    """
    word = bare(word)
    if not word:
        return ""
    codes = {
        **dict.fromkeys("bfpv", "1"),
        **dict.fromkeys("cgjkqsxz", "2"),
        **dict.fromkeys("dt", "3"),
        **dict.fromkeys("l", "4"),
        **dict.fromkeys("mn", "5"),
        **dict.fromkeys("r", "6"),
    }
    first, rest = word[0], word[1:]
    out = ""
    previous = codes.get(first, "")
    for character in rest:
        code = codes.get(character, "")
        if code and code != previous:
            out += code
        if character not in "hw":
            previous = code
    return (first.upper() + out + "000")[:4]


def sounds_alike(a, b):
    """
    Two words are treated as a mishearing of one another if they share a soundex
    code or simply look close in letters. Homophones ("spare"/"spear") tend to
    fail one test and pass the other, so either is enough.
    """
    x, y = bare(a), bare(b)
    if not x or not y:
        return False
    if x == y:
        return True
    if soundex(x) == soundex(y) and soundex(x):
        return True
    return difflib.SequenceMatcher(None, x, y).ratio() >= 0.62


# ---------------------------------------------------------------- classifying

# Bucket -> (heading, what it implies). Order is the order they print in.
BUCKETS = [
    ("acoustic", "Acoustic — the recognizer misheard a word",
     "fix with vocabulary, then a better speech model"),
    ("dropped_head", "Dropped opening — words missing from the start",
     "audio lost before the tap delivered; a capture problem, not a model one"),
    ("dropped_tail", "Dropped ending — words missing from the end",
     "the 400ms tail after release may not be enough"),
    ("sentence_break", "Sentence breaks — punctuation added by hand",
     "fix in the cleaner or the polisher"),
    ("filler", "Fillers the cleaner left in",
     "fix with a rule in TranscriptDisfluencyCleaner"),
    ("capitalisation", "Capitalisation only",
     "fix in the cleaner"),
    ("punctuation", "Other punctuation",
     "fix in the cleaner or the polisher"),
    ("reword", "Rewording — heard right, said differently",
     "the user changing their mind; not an error to fix"),
]

BUCKET_KIND = {
    "acoustic": "acoustic",
    "dropped_head": "capture",
    "dropped_tail": "capture",
    "sentence_break": "contextual",
    "filler": "contextual",
    "capitalisation": "contextual",
    "punctuation": "contextual",
    "reword": "intent",
}


def classify(before, after):
    """
    Diff two token lists and yield (bucket, before_text, after_text) for each
    change. One send can produce several changes of different kinds.
    """
    matcher = difflib.SequenceMatcher(a=[bare(t) for t in before],
                                      b=[bare(t) for t in after])
    opcodes = matcher.get_opcodes()

    for index, (tag, i1, i2, j1, j2) in enumerate(opcodes):
        if tag == "equal":
            continue

        old = before[i1:i2]
        new = after[j1:j2]
        old_text = " ".join(old)
        new_text = " ".join(new)

        old_words = [t for t in old if not is_punct(t)]
        new_words = [t for t in new if not is_punct(t)]

        # Punctuation-only churn, before anything else looks at the words.
        if not old_words and not new_words:
            added = "".join(new)
            bucket = "sentence_break" if any(c in added for c in ".?!") else "punctuation"
            yield bucket, old_text, new_text
            continue

        # Words appearing at the very start or end of the send with nothing
        # replaced are almost always audio that never arrived, not an edit.
        at_start = index == 0
        at_end = index == len(opcodes) - 1
        if tag == "insert" and new_words:
            if at_start:
                yield "dropped_head", "", new_text
                continue
            if at_end:
                yield "dropped_tail", "", new_text
                continue

        if tag == "delete":
            removed = [w for w in old_words if bare(w) in FILLERS]
            yield ("filler" if removed and len(removed) == len(old_words) else "reword",
                   old_text, new_text)
            continue

        if tag == "insert":
            yield "reword", old_text, new_text
            continue

        # replace — the interesting case.
        if len(old_words) == len(new_words):
            pairs = list(zip(old_words, new_words))
            if all(bare(a) == bare(b) for a, b in pairs):
                yield "capitalisation", old_text, new_text
                continue
            if all(sounds_alike(a, b) for a, b in pairs):
                yield "acoustic", old_text, new_text
                continue
        elif len(old_words) == 1 and len(new_words) > 1 and sounds_alike(
                old_words[0], "".join(new_words)):
            # "everyone" heard as "every one", and the reverse.
            yield "acoustic", old_text, new_text
            continue

        yield "reword", old_text, new_text


# ------------------------------------------------------------------- the pass

def load(path):
    rows = []
    with open(path, "r", encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                print(f"  (skipped unreadable line {number})", file=sys.stderr)
    return rows


def analyse(rows):
    buckets = defaultdict(list)
    substitutions = Counter()
    vocabulary = Counter()
    reverted = Counter()
    edited = 0

    for row in rows:
        raw = row.get("raw", "")
        cleaned = row.get("cleaned", "")
        sent = row.get("sent", "")
        if sent == cleaned:
            continue
        edited += 1

        before, after = tokenize(cleaned), tokenize(sent)
        raw_words = {bare(t) for t in tokenize(raw)}

        for bucket, old_text, new_text in classify(before, after):
            buckets[bucket].append((old_text, new_text, row))

            if bucket == "acoustic":
                old_words = [t for t in tokenize(old_text) if not is_punct(t)]
                new_words = [t for t in tokenize(new_text) if not is_punct(t)]
                if len(old_words) == len(new_words):
                    for a, b in zip(old_words, new_words):
                        if bare(a) != bare(b):
                            substitutions[(a.lower(), b)] += 1
                else:
                    substitutions[(old_text.lower(), new_text)] += 1

            # A word the user typed that the microphone never produced is a word
            # the recognizer has no way to reach. Those are the vocabulary.
            if bucket in ("acoustic", "dropped_head", "dropped_tail"):
                for token in tokenize(new_text):
                    if is_punct(token) or len(bare(token)) < 3:
                        continue
                    if bare(token) not in raw_words:
                        vocabulary[token] += 1

        # Did the cleaner change something the user then put back? That is the
        # cleaner making the transcript worse, and it is worth its own count.
        if raw and raw != cleaned:
            raw_tokens = tokenize(raw)
            cleaned_tokens = tokenize(cleaned)
            sent_bare = [bare(t) for t in after]
            cleaner_matcher = difflib.SequenceMatcher(
                a=[bare(t) for t in raw_tokens], b=[bare(t) for t in cleaned_tokens])
            for tag, i1, i2, _, _ in cleaner_matcher.get_opcodes():
                if tag in ("delete", "replace"):
                    removed = [bare(t) for t in raw_tokens[i1:i2] if not is_punct(t)]
                    if removed and all(word in sent_bare for word in removed):
                        reverted[" ".join(raw_tokens[i1:i2])] += 1

    return buckets, substitutions, vocabulary, reverted, edited


# -------------------------------------------------------------------- output

def bar(count, total, width=28):
    if not total:
        return ""
    filled = int(round(width * count / total))
    return "█" * filled + "·" * (width - filled)


def truncate(text, limit=68):
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def report(rows, buckets, substitutions, vocabulary, reverted, edited, examples):
    total = len(rows)
    changes = sum(len(v) for v in buckets.values())

    print()
    print("=" * 76)
    print("  CAW CORPUS REPORT")
    print("=" * 76)
    print()
    print(f"  {total} sends recorded, {edited} of them edited "
          f"({percent(edited, total)} needed a correction)")
    print(f"  {changes} separate corrections across those sends")
    if rows:
        stamps = sorted(r.get("timestamp", "") for r in rows if r.get("timestamp"))
        if stamps:
            print(f"  {stamps[0][:10]} to {stamps[-1][:10]}")

    destinations = Counter(r.get("destination", "?") for r in rows)
    edit_rate = Counter()
    for row in rows:
        if row.get("sent") != row.get("cleaned"):
            edit_rate[row.get("destination", "?")] += 1
    print()
    print("  Where it went")
    for name, count in destinations.most_common():
        print(f"    {name:<34} {count:>4} sends, "
              f"{percent(edit_rate[name], count)} edited")

    # The headline: what kind of problem is this.
    kinds = Counter()
    for bucket, items in buckets.items():
        kinds[BUCKET_KIND[bucket]] += len(items)
    print()
    print("-" * 76)
    print("  THE ANSWER: what kind of errors are left")
    print("-" * 76)
    print()
    for kind, label in [
        ("acoustic", "Acoustic   — the recognizer misheard"),
        ("contextual", "Contextual — heard right, formatted wrong"),
        ("capture", "Capture    — audio never arrived"),
        ("intent", "Intent     — the user changed their mind"),
    ]:
        count = kinds.get(kind, 0)
        print(f"  {label:<44} {count:>4}  {percent(count, changes):>5}  "
              f"{bar(count, changes)}")
    print()
    fixable = kinds.get("acoustic", 0) + kinds.get("contextual", 0) + kinds.get("capture", 0)
    if fixable:
        leader = max(("acoustic", "contextual", "capture"), key=lambda k: kinds.get(k, 0))
        print(f"  Largest fixable share: {leader} "
              f"({percent(kinds.get(leader, 0), fixable)} of fixable corrections)")

    print()
    print("-" * 76)
    print("  BREAKDOWN")
    print("-" * 76)
    for bucket, heading, implication in BUCKETS:
        items = buckets.get(bucket, [])
        if not items:
            continue
        print()
        print(f"  {heading}  —  {len(items)}  ({percent(len(items), changes)})")
        print(f"    → {implication}")
        for old_text, new_text, _ in items[:examples]:
            print(f"      {truncate(old_text) or '(nothing)':<70}")
            print(f"        ↳ {truncate(new_text) or '(removed)'}")

    if substitutions:
        print()
        print("-" * 76)
        print("  WORDS THE RECOGNIZER KEEPS GETTING WRONG")
        print("-" * 76)
        print("  heard → meant, most repeated first.")
        print()
        for (heard, meant), count in substitutions.most_common(25):
            marker = "  ←" if count > 1 else ""
            print(f"    {heard:<28} → {meant:<28} {count:>3}{marker}")

    if vocabulary:
        print()
        print("-" * 76)
        print("  VOCABULARY CANDIDATES")
        print("-" * 76)
        print("  Words typed by hand that the microphone never produced. These are")
        print("  what contextualStrings exists for — see LiveTranscriptionController.")
        print()
        picks = [(word, count) for word, count in vocabulary.most_common(40) if count > 1]
        if not picks:
            picks = vocabulary.most_common(15)
        line = "    "
        for word, count in picks:
            piece = f"{word}({count})  "
            if len(line) + len(piece) > 74:
                print(line)
                line = "    "
            line += piece
        print(line)

    if reverted:
        print()
        print("-" * 76)
        print("  CLEANUP THE USER PUT BACK")
        print("-" * 76)
        print("  The cleaner removed these and the user restored them by hand —")
        print("  each one is a cleaner rule that is too aggressive.")
        print()
        for text, count in reverted.most_common(15):
            print(f"    {truncate(text, 60):<62} {count:>3}")

    print()


def percent(part, whole):
    return f"{(100.0 * part / whole):.0f}%" if whole else "—"


def vocabulary_only(vocabulary):
    for word, count in vocabulary.most_common():
        if count > 1:
            print(f"{word}\t{count}")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--file", default=DEFAULT_CORPUS)
    parser.add_argument("--examples", type=int, default=4,
                        help="worked examples shown per bucket (default 4)")
    parser.add_argument("--vocab", action="store_true",
                        help="print only the vocabulary candidates, tab separated")
    args = parser.parse_args()

    if not os.path.exists(args.file):
        print(f"No corpus at {args.file}", file=sys.stderr)
        print("Dictate a few things with 'Save Corrections for Training' on.",
              file=sys.stderr)
        return 1

    rows = load(args.file)
    if not rows:
        print("The corpus is empty.", file=sys.stderr)
        return 1

    buckets, substitutions, vocabulary, reverted, edited = analyse(rows)

    if args.vocab:
        vocabulary_only(vocabulary)
        return 0

    if not edited:
        print(f"\n  {len(rows)} sends, none of them edited. Nothing to analyse yet.\n")
        return 0

    report(rows, buckets, substitutions, vocabulary, reverted, edited, args.examples)
    return 0


if __name__ == "__main__":
    sys.exit(main())
