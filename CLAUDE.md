# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS app that records audio — the microphone, the Mac's own output, or both
on separate tracks — or takes a file you already have, transcribes it, and
shows a speaker-labelled, editable transcript. Transcription happens either at
ElevenLabs (Scribe v2) or entirely on this Mac (Apple Speech plus FluidAudio
diarisation, Apple silicon and macOS 26 only).

It is a personal tool for transcribing Portuguese-language legal meetings. That
is not a detail: the audio is privileged, the vocabulary is specialised, and
the machine it has to run on is old.

## Hard constraints — do not change these without asking

- **Deployment target macOS 13.0, universal (arm64 + x86_64).** The app runs on
  a 2017 Intel MacBook. Raising the target produces a build that cannot launch
  on the machine it exists for. `build.sh` refuses to proceed if the installed
  Xcode can no longer target 13.0, and verifies both slices against the built
  Mach-O afterwards.
- **Two packages, both taken on deliberately: Sparkle and FluidAudio.**
  Otherwise Foundation, SwiftUI, AppKit, AVFoundation, ScreenCaptureKit,
  Speech, Security, UniformTypeIdentifiers and nothing else. Sparkle replaces a
  running application, which is hard to get right by hand; FluidAudio supplies
  the Core ML speaker diarizer that Apple's Speech framework does not. **Do not
  add a third package without asking.**
- **`UpdaterService.swift` is wrapped in `#if canImport(Sparkle)`.** The app
  builds and runs without that package; updating is simply absent. Keep it that
  way.
  **`LocalTranscriptionService.swift` imports FluidAudio unconditionally**, so
  unlike Sparkle it is not optional: a checkout whose packages have not been
  resolved no longer compiles. That is the current state, not an accident to
  tidy away silently — if you make it optional, do it the way Sparkle is done
  and say so.
- **Signed with a named self-signed identity, not ad-hoc.** The app target uses
  `CODE_SIGN_IDENTITY = "Rosy Transcribe Local Signing"`, manual signing, App
  Sandbox **off**, hardened runtime **off**. The identity is not cosmetic:
  microphone and screen-recording permissions are granted to a *signature*, and
  an ad-hoc signature changes on every build, so macOS would forget both grants
  every time the app is rebuilt. `build.sh` fails the build if it detects an
  ad-hoc fallback. The test target stays ad-hoc (`-`) on purpose. The README
  explains how to create the certificate; without it, the project does not
  build.
- **Installation is still copy-and-right-click-Open.** Self-signed is not
  notarised, so Gatekeeper refuses a plain double-click the first time.
- **Performance target is the 2017 dual-core Intel machine**, not the M4 it is
  built on. That is why the transcript list is lazy and why search results are
  cached rather than recomputed per row.

## Commands

```sh
./build.sh                          # preflight, tests, universal Release, verify
python3 Tools/validate_pbxproj.py   # after any hand-edit of the project file
python3 Tools/make_icon.py          # regenerate the app icon
./Tools/release.sh                  # build, zip, sign, print the appcast entry
python3 Tools/set_update_key.py KEY  # set the Sparkle public key safely
```

Tests, without the full build:

```sh
xcodebuild test -project RosyTranscribe.xcodeproj -scheme RosyTranscribe \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

A single class or case:

```sh
xcodebuild test -project RosyTranscribe.xcodeproj -scheme RosyTranscribe \
  -destination 'platform=macOS' \
  -only-testing:RosyTranscribeTests/TranscriptSearchTests/testSearchIsDiacriticInsensitive
```

## Architecture

The codebase is split into a **pure core** and a **UI shell**, and that split is
load-bearing.

**Pure** — no SwiftUI and no networking, all directly unit-tested:

| File | Responsibility |
|---|---|
| `TranscriptFormatter.swift` | `words[]` → speaker turns; two-track meeting assembly; labels; plain-text and Markdown rendering |
| `SpeakerEditor.swift` | Reassigning, splitting, editing and detaching segments |
| `TranscriptSearch.swift` | Finding text |
| `Keyterms.swift` | Glossary parsing and limits |
| `SpeakerColor.swift` | The palette, as names — no `Color` |
| `TranscriptRecord.swift` | The saved transcript and its on-disk store |
| `SettingsModels.swift` | Settings value types, their JSON stores and documents, ignored-segment filtering, engine fallback, the endpoint policy, and the provider registry |
| `MultipartBuilder.swift`, `Models.swift` | Wire format and response decoding |

`SettingsModels.swift` is the one file that bends the rule: `CloudTranscriptionRegistry`
is `@MainActor` and `ObservableObject`, because the picker has to react when a
provider is disabled. Everything else in it is a plain value type, and the
stores touch only the file system.

**Shell** — the parts that touch the platform:

| File | Responsibility |
|---|---|
| `ContentView.swift` | `TranscriberModel` (`@MainActor`, all app state) plus Home, Recording and Transcription |
| `SettingsView.swift` | The five settings panes |
| `TranscriptionService.swift` | The ElevenLabs call, timeouts, error mapping |
| `LocalTranscriptionService.swift` | Apple Speech + Core ML diarization and timeline alignment |
| `AudioRecordingService.swift` | Microphone and system capture, levels, permissions, recording storage |
| `AudioPlaybackService.swift` | `AVPlayer` wrapper for local playback and seeking |
| `SegmentTextView.swift` | `NSTextView` wrapper for one transcript segment |
| `KeychainStore.swift` | Every secret: the ElevenLabs key and any AI-service keys |
| `UpdaterService.swift` | Sparkle, behind `canImport` |

**The test target compiles the sources it tests directly** rather than importing
the app module, so tests need no host application and no `@testable import`.
That now includes three shell files — `LocalTranscriptionService.swift`,
`AudioRecordingService.swift` and `SegmentTextView.swift` — so the test target
links FluidAudio as well. **`ContentView.swift` and `SettingsView.swift` are
deliberately not in the test target**, which is exactly why logic must not
accumulate inside them.

A full code review of this project found **every defect in `ContentView`'s
wiring of the pure core, and none in the core itself.** New logic belongs in a
pure file with tests; the views should stay thin enough to read.

## Where the data lives

Everything is under `~/Library/Application Support/RosyTranscribe/`, written
`0600` inside a `0700` directory. These are recordings of privileged meetings;
the default world-readable mode is more exposure than they deserve on any
shared machine.

| Path | What it holds |
|---|---|
| `Transcripts/<uuid>.json` | One saved transcript each, pretty-printed |
| `Recordings/<uuid>/microphone.caf`, `system.caf` | Audio **Rosy recorded itself**, one folder per session |
| `CloudTranscriptionProviders.json` | Which cloud engines are registered and enabled |
| `People.json` | The People directory: names, aliases, colours, who is "You" |
| `IgnoredSegments.json` | Whole-segment hide rules |
| `AIServices.json` | Registered AI services — **metadata only, never keys** |

Secrets live in the login Keychain under service `com.rosy.RosyTranscribe`:
account `elevenlabs-api-key`, plus one account per AI service, named with that
service's UUID.

Preferences live in `UserDefaults`: `transcriptionLanguage`, `keyterms`,
`transcriptionEngine`, `expectedSpeakers`, `remoteSpeakers`.

Audio the **user** chose is never copied anywhere; a transcript stores its path
only. Audio **Rosy recorded** is Rosy's to keep, and currently nothing deletes
it except discarding a recording before use.

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
6. **`TranscriptFormatter.merged` preserves combined timings.** It is used for
   readable output and after reassignment, where newly adjacent turns owned by
   the same speaker become one segment. An untouched Return split keeps its
   boundary until reassignment resolves it.
7. **`commitEdit` clears `fallbackText` when the last segment is deleted.**
   `format` falls back to the flat API text when there are no turns, so without
   this, emptying the only segment silently resurrects the transcript and saves
   it that way.
8. **`speaker_0` displays as "Speaker 1"; a nil speaker displays as "Unknown".**
   Deleting a speaker detaches their segments rather than deleting them.
9. **`TranscriptRecord.speakerOrder` is optional** so that records written
   before it existed still decode. Do not make it required. The same applies to
   every field added since: `audioPath`, `secondaryAudioPath`, `recordingMode`,
   `remoteSpeakers`, `speakerPersonIDs` and `unfilteredTurns`.
10. **Search is diacritic-insensitive on purpose.** The transcripts are
    Portuguese; `averbacao` must find `averbação`.
11. **Highlight ranges convert to `NSRange` through the UTF-16 view**, not by
    counting characters.
12. **Segments must stay `NSTextView`-backed.** SwiftUI's `Text` is selectable
    but not editable; `TextField` is editable but cannot render highlighted
    ranges on macOS 13. Only `NSTextView` gives click-to-caret, drag-select,
    editing, search highlighting and Option-click-to-seek simultaneously.
13. **Audio paths and word timings are optional.** Records from before playback
    support contain neither and must continue to decode. The path points to a
    recording; never copy a file the user chose into the transcript library.
14. **Missing audio is normal.** Keep the transcript usable, show “Playback
    Unavailable — Audio file not found”, and offer Relink Audio. Never treat a
    deleted post-meeting recording as a corrupt transcript.
15. **Return splits a segment; it does not insert a newline.** Both halves keep
    the original speaker so one can then be reassigned. Refuse empty edge
    splits, and preserve word timings only when the split still matches an
    exact boundary in the API's original words.
16. **`speaker_local` is the microphone track.** A voice note, and the local
    half of a meeting, are forced to that id. It displays as "You", or as the
    name and colour of the People-directory person marked "You".
17. **A meeting with Remote speakers = 1 skips diarisation entirely.** Both
    tracks are transcribed undiarised, the system track is forced to
    `speaker_0`, and the microphone stays `speaker_local`. With two or more, only
    the system track is diarised, and that count becomes its clustering target.
    Knowing which file came from which device is stronger evidence than voice
    clustering; do not throw it away.
18. **Two-track playback assumes both files start at t = 0.** The composition
    inserts both at `.zero`, and `meetingTurns` merges them onto one timeline on
    the same assumption. Capture starts system audio *before* the microphone, so
    a delay there becomes permanent drift. Any alignment fix has to change
    capture, playback and assembly together.
19. **Secrets never enter the settings JSON.** Keys go to the Keychain; the JSON
    stores hold metadata only, and `SettingsModelsTests` asserts the persisted
    text contains no `key`.
20. **`registerElevenLabsIfMissing` must never re-enable a disabled provider.**
    Adopting a credential from an older build is not permission to undo a
    deliberate "off". A test pins this.
21. **Ignored-segment rules match whole segments only**, after normalising
    whitespace, case and diacritics. A longer sentence that merely contains the
    phrase is left alone. `unfilteredTurns` keeps the pre-filter turns so
    Restore is possible, and rules are applied at transcription time only —
    never retroactively to a transcript on disk.
22. **The `SpeakerColor` → SwiftUI `Color` mapping lives in exactly one place**,
    the extension in `ContentView.swift`. A second mapping elsewhere silently
    gives one person two different colours in two panels.
23. **No file-system reads inside a SwiftUI `body`.** Settings files are loaded
    once into state, not re-read per row. This is the dual-core rule, and the
    People rows are the place it is easiest to break. Note that `@State`'s
    default value is an ordinary expression, re-evaluated on every view
    construction — `@StateObject` is the one that evaluates once.
24. **The People directory and the ignored-segment rules have one owner**,
    `SharedSettings`. Both Settings and the transcript read them, and a second
    copy is a copy that goes stale the moment somebody is renamed.
25. **A settings pane binds straight into its document**, and the document
    persists itself. Do not reintroduce a `persist…()` helper that a caller has
    to remember: every bug in the first version of that screen — a rename lost,
    a rule toggle lost — was exactly that call being forgotten. Structural
    edits save at once; text edits are debounced and flushed on the way out.
26. **Plain HTTP is allowed only to a loopback or RFC1918 *address*.**
    `LocalEndpointPolicy` parses the host; it does not prefix-match it, because
    `10.evil.example.com` is a public hostname that a prefix test accepts.

## The rename, and the two strings that carry data

The app was **Scribe Droplet** until it became **Rosy Transcribe**. Two strings
in that rename were not cosmetic, because they name where user data lives:

- `com.rosy.RosyTranscribe` — the Keychain service holding the API key
- `~/Library/Application Support/RosyTranscribe/Transcripts/` — the library

Changing either without a migration makes the app launch clean and empty: no
key, no transcripts, nothing obviously broken. Both migrations exist and run
once at startup, before anything reads either location:

- `KeychainStore.migrateRenamedServiceIfNeeded()` — copies the key from
  `com.rosy.ScribeDroplet` only if the current service holds nothing.
- `TranscriptStore.migrateRenamedDirectory(from:to:)` — moves the library only
  if the destination does not exist, so it can never merge two libraries or
  overwrite newer transcripts with older ones. Tested.

**Leave both in place.** They are cheap, they run once, and deleting them
orphans the data of anyone still on a pre-rename build. If the app is ever
renamed again, add a third migration rather than editing these — each one
knows exactly which past name it inherits from.

## Working in a cloud session

Cloud sessions have **no Xcode and no Swift toolchain**, so nothing can be
compiled or run here. Do not claim otherwise. Nothing that depends on Apple
Speech, ScreenCaptureKit or FluidAudio can be checked at all — those are
macOS 26 and Apple-silicon paths that even the M4 cannot fully exercise from a
terminal. What works instead:

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

**Recording is built.** Home offers Voice Note, System Audio, Meeting and
Transcribe a File. Meeting keeps the microphone and the Mac's output as two
independent files, which is what makes the local speaker recoverable when
diarisation struggles.

**Audio playback is built.** Records keep the source path and per-word timing;
the app provides transport controls, per-segment play, Option-click word seek,
and relinking when the original file moves. Editing a segment can make its word
boundaries diverge from the API response; in that case seeking honestly falls
back to the start of the segment rather than guessing.

**Settings is built** — five panes: Cloud Transcription, Local Transcription,
People, Ignored Segments, AI Services. The AI Services pane is **scaffolding**:
it registers providers and stores their keys, and nothing in the app makes a
request with them yet.

**Publishing an update.** `Tools/release.sh` does the build, the zip and the
signature; it then prints an `<item>` to paste into `appcast.xml`. Both halves
are required — the appcast is what the app reads, the GitHub release is where
the file it names actually lives. Bump `MARKETING_VERSION` *and*
`CURRENT_PROJECT_VERSION` first: Sparkle orders updates by `CFBundleVersion`,
so a build that does not increase is a build nobody is ever offered.

**A real icon.** The current one is a placeholder — `Tools/make_icon.py` draws
it from a handful of constants at the top of the file.

### Known limitations, accepted for now

- **Undo is document-scoped.** Native text controls provide ordinary typing
  undo, while segment splitting, speaker reassignment, bulk reassignment,
  speaker addition/removal and colour changes register structural snapshots
  with the macOS Undo Manager. Opening another transcript clears that history
  so ⌘Z can never modify the wrong document.
- **Selection cannot span two segments,** since each row is its own text view.
  Spanning would mean collapsing the transcript into one continuous view and
  losing the two-column layout. Copy All and the Markdown export cover wanting
  the whole thing.
- **Find searches segment text only** — not speaker names, and not the flat
  `fallbackText` shown when a transcript came back without diarization. Find is
  disabled in that second case rather than silently answering "No matches".
  There is no keyboard shortcut for the previous match; Return advances, and
  the chevrons step both ways.
- **Key terms apply to ElevenLabs only.** The field is disabled in local mode
  and says so.
- **The local engine cannot detect a language.** Apple's `SpeechTranscriber`
  does not guess, so Auto follows the Mac's current locale.
- **Recordings are never cleaned up.** Discarding one before use deletes it;
  after that, deleting a transcript leaves its audio on disk and there is no
  in-app way to see or remove it.
