# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS app that uploads an audio file to the ElevenLabs Scribe API and shows a
speaker-labelled, editable transcript. It is a personal tool for transcribing
Portuguese-language legal meetings.

## Hard constraints — do not change these without asking

- **Deployment target macOS 13.0, universal (arm64 + x86_64).** The app runs on
  a 2017 Intel MacBook. Raising the target produces a build that cannot launch
  on the machine it exists for. `build.sh` refuses to proceed if the installed
  Xcode can no longer target 13.0, and verifies both slices against the built
  Mach-O afterwards.
- **No dependencies.** Foundation, SwiftUI, AppKit, Security, UniformTypeIdentifiers.
  No SPM packages.
- **App Sandbox off**, ad-hoc signing ("sign to run locally"). The app is
  installed by copying the `.app` across and right-click → Open once.
- **Performance target is the 2017 dual-core Intel machine**, not the M4 it is
  built on. That is why the transcript list is lazy and why search results are
  cached rather than recomputed per row.

## Commands

```sh
./build.sh                          # preflight, tests, universal Release, verify
python3 Tools/validate_pbxproj.py   # after any hand-edit of the project file
python3 Tools/make_icon.py          # regenerate the app icon
```

Tests, without the full build:

```sh
xcodebuild test -project ScribeDroplet.xcodeproj -scheme ScribeDroplet \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

A single class or case:

```sh
xcodebuild test -project ScribeDroplet.xcodeproj -scheme ScribeDroplet \
  -destination 'platform=macOS' \
  -only-testing:ScribeDropletTests/TranscriptSearchTests/testSearchIsDiacriticInsensitive
```

## Architecture

The codebase is split into a **pure core** and a **UI shell**, and that split is
load-bearing.

**Pure** — no SwiftUI, no networking, no file system (except the store), all
directly unit-tested:

| File | Responsibility |
|---|---|
| `TranscriptFormatter.swift` | `words[]` → speaker turns; labels; plain-text and Markdown rendering |
| `SpeakerEditor.swift` | Reassigning, editing and detaching segments |
| `TranscriptSearch.swift` | Finding text |
| `Keyterms.swift` | Glossary parsing and limits |
| `SpeakerColor.swift` | The palette, as names — no `Color` |
| `TranscriptRecord.swift` | The saved transcript and its on-disk store |
| `MultipartBuilder.swift`, `Models.swift` | Wire format and response decoding |

**Shell** — the parts that touch the platform:

| File | Responsibility |
|---|---|
| `ContentView.swift` | `TranscriberModel` (`@MainActor`, all app state) plus every view |
| `TranscriptionService.swift` | The API call, timeouts, error mapping |
| `SegmentTextView.swift` | `NSTextView` wrapper for one transcript segment |
| `KeychainStore.swift` | The API key |

**The test target compiles the pure sources directly** rather than importing the
app module, so tests need no host application and no `@testable import`.
`ContentView.swift` is deliberately not in the test target.

A full code review of this project found **every defect in `ContentView`'s
wiring of the pure core, and none in the core itself.** New logic belongs in a
pure file with tests; the view should stay thin enough to read.

## Invariants that are easy to break silently

These are load-bearing decisions, several learned from the live API or from
data already on users' disks.

1. **`SpeakerColor` cases are append-only.** Saved transcripts store the raw
   `Int`, so reordering recolours every speaker on disk. A test pins all ten.
2. **`keyterms` goes over the wire as repeated multipart parts, one per term** —
   not a JSON array. Sending JSON makes the server measure the whole array as a
   single keyword and reject with `All keywords must be less than 50 characters`.
3. **The keyterm length limit is exclusive (`< 50`).** The docs say "≤50"; the
   server disagrees, and the API wins.
4. **`language_code` and `keyterms` are omitted entirely when empty**, never
   sent blank. Empty is not the same as absent.
5. **Filter `words[]` on `type == "word"`.** `spacing` and `audio_event`
   entries otherwise litter the transcript.
6. **`TranscriptFormatter.merged` is output-only.** Adjacent same-speaker
   segments stay separate in the data so every reassignment and edit is
   reversible; they join only in rendered output.
7. **`commitEdit` clears `fallbackText` when the last segment is deleted.**
   `format` falls back to the flat API text when there are no turns, so without
   this, emptying the only segment silently resurrects the transcript and saves
   it that way.
8. **`speaker_0` displays as "Speaker 1"; a nil speaker displays as "Unknown".**
   Deleting a speaker detaches their segments rather than deleting them.
9. **`TranscriptRecord.speakerOrder` is optional** so that records written
   before it existed still decode. Do not make it required.
10. **Search is diacritic-insensitive on purpose.** The transcripts are
    Portuguese; `averbacao` must find `averbação`.
11. **Highlight ranges convert to `NSRange` through the UTF-16 view**, not by
    counting characters.
12. **Segments must stay `NSTextView`-backed.** SwiftUI's `Text` is selectable
    but not editable; `TextField` is editable but cannot render highlighted
    ranges on macOS 13. Only `NSTextView` gives click-to-caret, drag-select,
    editing and search highlighting simultaneously — and it is the groundwork
    for click-a-word-to-seek.

## Renaming the app

A rename is planned. Two strings are **not** cosmetic:

- `com.rosy.ScribeDroplet` — the Keychain service holding the API key
- `~/Library/Application Support/ScribeDroplet/Transcripts/` — the library

Changing either during a find-and-replace makes the app launch clean and empty:
no key, no transcripts. Keep them, or write a migration deliberately.

## Working in a cloud session

Cloud sessions have **no Xcode and no Swift toolchain**, so nothing can be
compiled or run here. Do not claim otherwise. What works instead:

- Port the logic to Python and test it there before committing.
- Run `python3 Tools/validate_pbxproj.py` after touching the project file.
- Check brace, paren and bracket balance across the Swift sources.

`project.pbxproj` is hand-edited. Its UUIDs are allocated by section:
`1A…` file references, `1B…` build files, `1C…` groups, `1D…` build phases,
`1E…` targets, `1F…` the project, `20…` configuration lists, `21…` build
configurations. Adding a source file means a new `1A` reference, one `1B` entry
per target it belongs to, a group entry, and an entry in each target's sources
phase.

## Roadmap

**Audio playback, and click-a-word-to-play.** The app has never opened the
audio — it uploads bytes and forgets them. Two things block this:

- *Where the audio lives.* The library stores no audio, so reopening a
  transcript next week has nothing to play. Either store the file's path
  (cheap, breaks when the file moves) or copy it in (robust, roughly 11 MB per
  40 minutes). Undecided.
- *The timestamps are thrown away.* `TranscriptFormatter.turns` keeps text and
  speaker and discards each word's `start`/`end`. Per-word seeking needs them
  kept, which changes the shape of a saved record.

When it is built, **bind seeking to ⌥-click or a per-segment play button, not
double-click** — double-click already means "select word" to the system, and
fighting that breaks ordinary text behaviour. `SegmentTextView` is `NSTextView`
partly so this is possible: it can map a click point to a character index.

**A real icon.** The current one is a placeholder — `Tools/make_icon.py` draws
it from a handful of constants at the top of the file.

**The rename.** See the section above; two strings must survive it.

### Known limitations, accepted for now

- **No undo for structural edits.** `NSTextView` gives undo *within* one
  segment, but deleting a segment, deleting a speaker, or reassigning has no
  undo. Every one of those is non-destructive by design — deleting a speaker
  detaches their segments rather than removing them, and reassignment keeps
  segments separate — so the damage is recoverable by hand, but there is no
  ⌘Z for it.
- **Selection cannot span two segments,** since each row is its own text view.
  Spanning would mean collapsing the transcript into one continuous view and
  losing the two-column layout. Copy All and the Markdown export cover wanting
  the whole thing.
- **Find searches segment text only** — not speaker names, and not the flat
  `fallbackText` shown when a transcript came back without diarization. Find is
  disabled in that second case rather than silently answering "No matches".
