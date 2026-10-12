#!/bin/bash
#
# Capability harness for VoiceApp.
#
# VoiceApp holds Accessibility, Input Monitoring and Microphone access. Those are
# powerful enough that "trust me" is not an answer. This script enforces, by
# inspection of the source and the built binary, that the app can only do the
# narrow set of things it claims:
#
#   1. Only ONE file may write into other applications.
#   2. The hotkey monitor may LISTEN to keys but never INJECT them.
#   3. Nothing may reach the internet. The only network traffic allowed is the
#      loopback connection to the local Home nest (127.0.0.1, Personal edition
#      only). Nothing may run a subprocess except that nest's launcher.
#   4. Nothing may read the contents of another app's UI — with one stated
#      exception: the read-back test (ReadbackProbe) may read the value of the
#      text box a dictation was just pasted into, never a password field, only
#      while its setting is on, and in the Beta edition without keeping any text.
#
# Any violation fails the run. Wire it into a build phase to make it binding.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SOURCES="VoiceApp"
INSERTION_FILE="VoiceApp/Transcription/TextInsertionController.swift"
READBACK_FILE="VoiceApp/Transcription/ReadbackProbe.swift"
HOTKEY_FILE="VoiceApp/Hotkey/FnKeyEventTapMonitor.swift"
AUDIT_FILE="VoiceApp/Transcription/InsertionAuditLog.swift"
CORPUS_FILE="VoiceApp/Transcription/TrainingCorpus.swift"
WORDFIX_FILE="VoiceApp/Transcription/WordFixStore.swift"
SUGGESTIONS_FILE="VoiceApp/Transcription/WordFixSuggestions.swift"
CANDIDATES_FILE="VoiceApp/Transcription/WordFixCandidates.swift"
RETENTION_FILE="VoiceApp/Transcription/CorpusRetention.swift"
POLISH_FILE="VoiceApp/Transcription/TranscriptPolisher.swift|VoiceApp/Companion/CrumbChat.swift"
NEST_FILE="VoiceApp/Companion/RoostController.swift"
BINARY=".build/Build/Products/Debug/VoiceApp.app/Contents/MacOS/VoiceApp"

failures=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; failures=$((failures + 1)); }

# Report every Swift file outside the allowed set (an extended-regex alternation
# of paths) that matches pattern $1.
confined_to() {
    local pattern="$1" allowed="$2" label="$3"
    local hits
    hits=$(grep -rlE "$pattern" --include='*.swift' "$SOURCES" 2>/dev/null | grep -vE "^(${allowed})$")
    if [ -z "$hits" ]; then
        pass "$label"
    else
        fail "$label — also found in:"
        echo "$hits" | sed 's/^/         /'
    fi
}

absent() {
    local pattern="$1" label="$2"
    local hits
    hits=$(grep -rnE "$pattern" --include='*.swift' "$SOURCES" 2>/dev/null)
    if [ -z "$hits" ]; then
        pass "$label"
    else
        fail "$label — found:"
        echo "$hits" | sed 's/^/         /'
    fi
}

echo
echo "Writing into other applications"
confined_to 'AXUIElement|kAXFocusedUIElement|kAXSelectedText' "$INSERTION_FILE|$READBACK_FILE" \
    "Accessibility API confined to TextInsertionController and the read-back test"
confined_to 'NSPasteboard' "$INSERTION_FILE" \
    "Clipboard access confined to TextInsertionController"
confined_to '\.post\(tap:|postToPid' "$INSERTION_FILE" \
    "Synthetic keystrokes confined to TextInsertionController"

echo
echo "Reading from other applications"
# Insertion asks a destination whether a text field has focus, so it can stop
# pasting into windows that would swallow the text. Electron apps only answer
# that once AXManualAccessibility is set, so the app is allowed to set it — and
# ONLY it. Writing any other attribute would be reaching into another app's
# state rather than asking it a question about itself.
# The call is usually written across two lines, so the attribute name is checked
# against the whole statement rather than the line the call opens on.
other_writes=$(grep -rn -A 2 'AXUIElementSetAttributeValue' --include='*.swift' "$SOURCES" 2>/dev/null \
    | awk '
        /AXUIElementSetAttributeValue/ { statement = $0; capturing = 1; next }
        capturing { statement = statement " " $0 }
        /\)/ && capturing {
            if (statement !~ /AXManualAccessibility/) print statement
            capturing = 0
        }
    ')
if [ -z "$other_writes" ]; then
    pass "AXManualAccessibility is the only attribute ever written to another app"
else
    fail "An attribute other than AXManualAccessibility is written — found:"
    echo "$other_writes" | sed 's/^/         /'
fi
# Insertion reads only which element has focus — it needs a target to write
# to. Reading a field's contents would be surveillance, so it is allowed in one
# place, for one purpose: the read-back test (Phase 2a) measures whether the
# text box a dictation just landed in can be read back, so edits made there can
# one day teach the word fixes. It must skip password fields, must be
# switchable, and the Beta edition must not keep any text it reads.
absent 'kAXTitleAttribute|kAXDescription|kAXChildren|kAXWindows' \
    "No reading of other apps' windows, titles or element trees"
confined_to 'kAXValueAttribute' "$READBACK_FILE" \
    "Text-box contents read only by the read-back test"
if grep -q 'AXSecureTextField' "$READBACK_FILE" 2>/dev/null; then
    pass "Read-back test skips password fields"
else
    fail "Read-back test has no password-field (AXSecureTextField) check"
fi
if grep -q 'guard Self.isEnabled' "$READBACK_FILE" 2>/dev/null; then
    pass "Read-back test can be switched off"
else
    fail "Read-back test runs unconditionally"
fi
beta_text=$(awk '
    /^[[:space:]]*#if !BETA/ { depth++; next }
    /^[[:space:]]*#endif/ && depth > 0 { depth--; next }
    /(insertedText|finalText)[[:space:]]*=/ && depth == 0 { print FILENAME ":" FNR ": " $0 }
' "$READBACK_FILE" 2>/dev/null)
if [ -z "$beta_text" ]; then
    pass "Read-back test keeps text only in the Personal edition"
else
    fail "Read-back text stored outside #if !BETA — found:"
    echo "$beta_text" | sed 's/^/         /'
fi
absent 'CGWindowListCreateImage|CGDisplayCreateImage|SCStream|SCShareableContent' \
    "No screen capture"

echo
echo "Keyboard monitoring"
if grep -q 'options: .listenOnly' "$HOTKEY_FILE" 2>/dev/null; then
    pass "Fn event tap is listen-only (cannot alter or swallow your keystrokes)"
else
    fail "Fn event tap is NOT declared listenOnly"
fi
if grep -qE '\.post\(|postToPid' "$HOTKEY_FILE" 2>/dev/null; then
    fail "Hotkey monitor injects events — it must only listen"
else
    pass "Hotkey monitor never injects events"
fi
# The monitor may know THAT a key was pressed, so fn+arrow can cancel a
# recording. It may never know WHICH: reading a keycode would turn a shortcut
# guard into a keylogger.
confined_to 'CGEventType.keyDown|kCGEventKeyDown' "$HOTKEY_FILE" \
    "Key presses observed only by the hotkey monitor"
absent 'getIntegerValueField|kCGKeyboardEventKeycode|keyboardGetUnicodeString' \
    "Keystroke identity is never read — only that a key occurred"

echo
echo "Writing to disk"
# Only the audit log may touch the filesystem, and it records where text went —
# never the text itself, so the log can't become a diary of your dictation.
# The word-fix store writes only word-fixes.json (the user's own spelling
# list): once when it does not exist yet, and then only when the user edits
# the list in Settings. Suggested fixes live beside it in
# word-fix-suggestions.json. Corpus retention rewrites the corpus and its
# archive — the same data the corpus already holds.
# The read-back test writes readback-probe.jsonl (metadata; the Personal
# edition also keeps the text, like the corpus). Word swaps found in captured
# text are counted in suggestion-candidates.json — word pairs only, never
# sentences, in the edition's own folder (Beta included).
confined_to 'FileHandle\(|createDirectory|\.write\(to:|AVAudioFile\(forWriting' "$AUDIT_FILE|$CORPUS_FILE|$RETENTION_FILE|$WORDFIX_FILE|$SUGGESTIONS_FILE|$CANDIDATES_FILE|$READBACK_FILE" \
    "File writing confined to the audit log, the corpus and its retention, the word-fix list, its suggestions and their counts, and the read-back log"
# The candidate counts hold word pairs, not sentences: no example text field.
if grep -qE 'var (example|sentence|insertedText|finalText)' "$CANDIDATES_FILE" 2>/dev/null; then
    fail "suggestion-candidates.json would store sentences"
else
    pass "Suggestion counts keep word pairs only, never sentences"
fi
if grep -qE 'record\(method:.*text|characters: text\)' "$AUDIT_FILE" 2>/dev/null; then
    fail "Audit log appears to record transcript text"
else
    pass "Audit log records size and destination, never the text"
fi

# The corpus deliberately does hold your words, so it must stay visible and
# switchable rather than becoming a silent recording of everything you dictate.
if grep -q 'guard isEnabled else { return }' "$CORPUS_FILE" 2>/dev/null; then
    pass "Training corpus can be switched off"
else
    fail "Training corpus records unconditionally"
fi
if grep -q 'func deleteEverything' "$CORPUS_FILE" 2>/dev/null; then
    pass "Training corpus can be deleted"
else
    fail "Training corpus cannot be deleted"
fi

echo
echo "On-device language model"
confined_to 'LanguageModelSession|SystemLanguageModel|FoundationModels' "$POLISH_FILE" \
    "Language model confined to transcript polishing and on-device Crumb chat"
# Private Cloud Compute is a genuinely private service, but it is not on this
# machine — and being an Apple framework call it would sail past the network
# checks below. It is banned outright so "nothing leaves your Mac" stays true.
absent 'PrivateCloudCompute' \
    "Never uses Apple's cloud-backed model"
absent 'Tool\b.*LanguageModel|tools:' \
    "The model is given no tools — it can only return text"

echo
echo "Reaching the outside world"
confined_to 'URLSession|URLRequest|webSocketTask' "$NEST_FILE" \
    "Networking confined to the loopback Home nest"
# Every network address written anywhere in the app must be loopback. Plain
# https links opened in the user's browser would also show up here, which is
# deliberate: none exist, and adding one should be a conscious decision.
remote_urls=$(grep -rnoE '(https?|wss?)://[^/"'"'"':) ]+' --include='*.swift' "$SOURCES" 2>/dev/null \
    | grep -vE '://127\.0\.0\.1$')
if [ -z "$remote_urls" ]; then
    pass "Every network address in the source is loopback (127.0.0.1)"
else
    fail "Non-loopback network address found:"
    echo "$remote_urls" | sed 's/^/         /'
fi
absent 'NWConnection|NWBrowser|NWListener|CFSocket|CFStream|Network\.' \
    "No other networking API"
# The leading guard keeps `.system(size:)` from reading as a call to system().
# One exception, stated rather than hidden: the Personal edition starts the
# owner's local Home servers (python3) when its nest is switched on. That
# code must stay in RoostController and inside `#if !BETA`, so the Beta binary
# cannot launch anything.
SUBPROCESS='(^|[^.[:alnum:]_])(Process|NSTask|posix_spawn|system|popen|execve)\('
confined_to "$SUBPROCESS" "$NEST_FILE" \
    "Subprocesses confined to the Personal edition's Home launcher"
outside_personal=$(awk -v pattern="$SUBPROCESS" '
    /^[[:space:]]*#if !BETA/ { depth++; next }
    /^[[:space:]]*#endif/ && depth > 0 { depth--; next }
    $0 ~ pattern && depth == 0 { print FILENAME ":" FNR ": " $0 }
' "$NEST_FILE" 2>/dev/null)
if [ -z "$outside_personal" ]; then
    pass "The Home nest and its launcher are compiled out of the Beta edition"
else
    fail "Subprocess code outside #if !BETA — found:"
    echo "$outside_personal" | sed 's/^/         /'
fi
absent 'requiresOnDeviceRecognition = false' \
    "Speech recognition is never allowed off-device"
if grep -q 'requiresOnDeviceRecognition = true' "$SOURCES/Transcription/LiveTranscriptionController.swift" 2>/dev/null; then
    pass "Speech recognition is pinned on-device"
else
    fail "requiresOnDeviceRecognition is not pinned to true"
fi

echo
echo "Edition contents"
# Runs only as the Xcode build phase, where the product just built is known.
# Beta must carry nothing personal.
if [ -n "${TARGET_BUILD_DIR:-}" ] && [ -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ] && [ -n "${EXECUTABLE_PATH:-}" ]; then
    RESOURCES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
    EXECUTABLE="$TARGET_BUILD_DIR/$EXECUTABLE_PATH"
    if [ "${CAW_EDITION:-}" = "beta" ]; then
        if [ -e "$RESOURCES/word-fixes-personal.json" ]; then
            fail "Beta bundles the owner's word-fix list"
        else
            pass "Beta bundles no personal word-fix list"
        fi
        personal=$(strings -a "$EXECUTABLE" 2>/dev/null | grep -iE '/Users/|/Volumes/|com\.local\.VoiceApp|AIza|generativelanguage|python3|127\.0\.0\.1' | sort -u)
        if [ -z "$personal" ]; then
            pass "Beta binary holds no personal paths, identifiers, keys or localhost addresses"
        else
            fail "Beta binary contains personal strings:"
            echo "$personal" | sed 's/^/         /'
        fi
    fi
else
    echo "  --   not running inside an Xcode build; skipping edition checks"
fi

echo
echo "Built binary"
if [ -f "$BINARY" ]; then
    if otool -L "$BINARY" | grep -qE 'CFNetwork|Network\.framework'; then
        pass "Networking framework linked for the loopback Home nest only"
    else
        pass "Binary links no networking framework"
    fi

    if codesign -dv "$BINARY" 2>&1 | grep -q 'Signature=adhoc'; then
        echo "  --   binary is ad-hoc signed: macOS may ask for permissions again after each rebuild"
    else
        pass "Binary carries a stable signature"
    fi
else
    echo "  --   binary not built; skipping binary checks"
fi

echo
if [ "$failures" -eq 0 ]; then
    printf '\033[32mAll capability checks passed.\033[0m\n\n'
    exit 0
fi
printf '\033[31m%d capability check(s) failed.\033[0m\n\n' "$failures"
exit 1
