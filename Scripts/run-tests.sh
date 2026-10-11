#!/bin/bash
#
# Builds and runs the standalone test programs in Scripts/Tests. Each test is
# compiled together with the exact app source files it exercises, so it tests
# the shipping code rather than a copy. Nothing here touches the real
# Application Support data; tests that need files make their own in a
# temporary folder.
#
#   Scripts/run-tests.sh

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

WORK=$(mktemp -d "${TMPDIR:-/tmp}/caw-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
failures=0

run() {
    local name="$1"; shift
    echo "── $name"
    if ! xcrun swiftc -parse-as-library -O "$@" -o "$WORK/$name" 2> "$WORK/$name.log"; then
        cat "$WORK/$name.log"; echo "FAIL: $name did not compile"; failures=$((failures + 1)); return
    fi
    if ! "$WORK/$name"; then
        echo "FAIL: $name"; failures=$((failures + 1))
    fi
}

run corpus-retention \
    VoiceApp/Transcription/CorpusRetention.swift \
    Scripts/Tests/corpus-retention-tests.swift

run corpus-hints \
    VoiceApp/Transcription/CorpusRetention.swift \
    VoiceApp/Transcription/CorpusVocabulary.swift \
    Scripts/Tests/corpus-hints-tests.swift

run readback \
    VoiceApp/Transcription/ReadbackAnalysis.swift \
    Scripts/Tests/readback-tests.swift

run chromium-detection \
    VoiceApp/Transcription/ChromiumAppDetection.swift \
    Scripts/Tests/chromium-detection-tests.swift

run word-fix-suggestions \
    VoiceApp/App/AppEdition.swift \
    VoiceApp/Transcription/TranscriptDisfluencyCleaner.swift \
    VoiceApp/Transcription/WordFixes.swift \
    VoiceApp/Transcription/WordFixStore.swift \
    VoiceApp/Transcription/WordFixSuggestions.swift \
    Scripts/Tests/word-fix-suggestions-tests.swift

run word-fix-mining \
    VoiceApp/App/AppEdition.swift \
    VoiceApp/Transcription/ReadbackAnalysis.swift \
    VoiceApp/Transcription/TranscriptDisfluencyCleaner.swift \
    VoiceApp/Transcription/WordFixes.swift \
    VoiceApp/Transcription/WordFixStore.swift \
    VoiceApp/Transcription/WordFixSuggestions.swift \
    VoiceApp/Transcription/WordFixMining.swift \
    VoiceApp/Transcription/WordFixCandidates.swift \
    Scripts/Tests/word-fix-mining-tests.swift

echo
if [ "$failures" -eq 0 ]; then echo "All tests passed."; exit 0; fi
echo "$failures test(s) failed."; exit 1
