# Caw

Caw is hold-to-talk dictation for macOS. Hold the Fn/Globe key (or click the
small floating pill), speak, let go, and the text appears where your cursor is.
You read it and press Return yourself; Caw never sends anything for you.

Caw was made by someone whose speech standard dictation doesn’t follow well: an
accent, a mumble, a lot of stopping and starting. It’s for anyone whose speech
gets lost the same way, including people who stutter. Pauses, restarts and
repeated sounds are expected, not treated as mistakes.

The Xcode project and product are still called `VoiceApp`.

## What makes it different: word learning

Every recognizer mishears some of your words the same way every time. Caw keeps
a list of those mishearings, which you approve and edit yourself: "when it
hears *this*, write *that*". The list lives in **Settings › Words & Learning**.
With **Learn From My Fixes** on, Caw notices when you correct a word right after
dictating it and suggests a fix; nothing is added to the list until you approve
it.

## Private by design

- Speech recognition runs on your Mac with Apple's speech engine. Network
  recognition is switched off.
- No accounts, no analytics, no network access.
- Optional extras (tidying punctuation, the Crumb chat) use Apple's on-device
  model only.
- `Scripts/verify-capabilities.sh` runs on every build and fails it if the code
  reaches for anything beyond this (network, screen capture, keystroke reading,
  writing into other apps outside one file).

## Install

You don't have to build Caw to use it.

1. Download `Caw-Beta-<version>.dmg` from the
   [latest release](https://github.com/birdbrainlabs/caw/releases/latest).
2. Open it and drag **Caw Beta** onto Applications.
3. Open Caw Beta from Applications. It is signed with a Developer ID and
   notarized by Apple, so macOS only asks once whether to open an app from the
   internet.
4. Grant **Microphone**, **Speech Recognition** and **Accessibility** when it
   asks (and Input Monitoring if it asks, for the Fn key), then hold Fn/Globe
   and talk.

It runs on Apple silicon and Intel Macs with macOS 14 or later.

## Requirements

- macOS 26 for the new speech engine. On older macOS (14 or later) Caw falls
  back to Apple's classic engine; you can also choose Classic in Settings.
- Xcode 26 or later to build.

## Build and run

1. Open `VoiceApp.xcodeproj` in Xcode.
2. Choose the **Caw Beta** scheme and run it. (The `VoiceApp` scheme builds the
   author's personal edition, which differs only in a few personal extras that
   are not part of this repo.)
3. Grant **Microphone**, **Speech Recognition** and **Accessibility** when
   macOS asks (and Input Monitoring if it asks, for the Fn key). Accessibility
   lets Caw paste at your cursor; without it, the text is copied and you press
   ⌘V.
4. Hold Fn/Globe and talk. A recording stops on its own after 5 minutes.

The project builds with an ad-hoc signature so anyone can build it. macOS may
ask for permissions again after you rebuild; to avoid that, set your own team
under Signing & Capabilities.

`Scripts/release-mac.sh` builds the signed, notarized download. It needs a
Developer ID certificate and Apple notarization credentials, so it only works
for the maintainer.

Tests: `Scripts/run-tests.sh` compiles and runs the standalone tests in
`Scripts/Tests`.

## Status

Personal project. It works for the author; no support is promised.

## Licence

- Code: MIT, see `LICENSE`.
- Artwork, the Crumb character, and the names Caw and Crumb:
  all rights reserved, see `ART-LICENSE.md`.
- Third-party code (three.js): see `THIRD_PARTY_LICENSES.md`.
