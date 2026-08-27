# Scribe Droplet

A small macOS app that takes a dropped audio file, sends it to the ElevenLabs
Scribe API, and shows a speaker-labelled transcript you can copy in one click.

Built for **Rosy** — a 2017 MacBook Retina 12" (Intel Core m3) on macOS Ventura
13.7. That machine cannot run local ML models, which is the whole reason the
transcription happens over an API.

- Deployment target: **macOS 13.0**
- Architecture: **universal (arm64 + x86_64)**
- Dependencies: **none.** Foundation, SwiftUI and AppKit only
- App Sandbox: **off** (personal tool, not an App Store submission)
- Signing: ad-hoc, "sign to run locally"

## Build

On the M4:

```sh
./build.sh
```

The script refuses to proceed if the installed Xcode can no longer target
macOS 13.0, runs the unit tests, builds a universal Release binary, and then
verifies against the built Mach-O that both slices are present and that neither
is stamped with a minimum OS above 13.0. An app that cannot launch on Rosy is a
silent failure, so none of those claims are taken on trust.

Output lands in `build/ScribeDroplet.app`.

You can also just open `ScribeDroplet.xcodeproj` and hit Run.

## Install on Rosy

Copy `ScribeDroplet.app` across, then **right-click → Open** the first time.
The app is signed to run locally, not notarised, so a plain double-click will
be refused by Gatekeeper. Once opened this way it launches normally thereafter.

## Use

1. Paste your ElevenLabs API key into the field at the top. It is remembered.
2. Pick a language, or leave it on Auto-detect.
3. Drop an audio file on the drop zone, or click it to pick one.
4. Transcribe. Long recordings take several minutes — most of it is upload.
5. Copy All.

## How it works

| File | Responsibility |
|---|---|
| `ScribeDropletApp.swift` | `@main`, a single window |
| `ContentView.swift` | The whole UI, plus the `@MainActor` view model |
| `TranscriptionService.swift` | The API call, timeouts, and error mapping |
| `MultipartBuilder.swift` | The `multipart/form-data` encoder |
| `Models.swift` | `Codable` structs for the response |
| `TranscriptFormatter.swift` | `words[]` → grouped speaker turns |

`TranscriptFormatter` and `MultipartBuilder` are free of UI and networking
types, which is what makes them testable without an API key. `ScribeDropletTests`
covers both, plus response decoding and the HTTP-status → message mapping.

### The API request

```
POST https://api.elevenlabs.io/v1/speech-to-text
xi-api-key: <key>
Content-Type: multipart/form-data; boundary=...

file                    the audio bytes, with filename and MIME type
model_id                scribe_v2
diarize                 true
timestamps_granularity  word
language_code           por | eng | spa   (omitted entirely for auto-detect)
```

The response carries `text`, `language_code`, `language_probability`,
`audio_duration_secs`, and `words[]`. Each word has `text`, `start`, `end`,
`speaker_id` and `type`.

**`type` is the one that matters.** It is `word`, `spacing`, or `audio_event`.
Only `word` entries are grouped into turns; including the others fills the
transcript with stray whitespace tokens and bracketed noises like `(laughter)`.

`speaker_id` comes back as `speaker_0`, `speaker_1`, … assigned in order of
first appearance — not by importance or by who talks most. It is displayed
one-indexed, so `speaker_0` shows as "Speaker 1".

### Limits

Per the current API reference: **5 GB** per direct upload, **10 hours** of
audio. The size limit is enforced client-side before the upload starts, so an
oversized file fails instantly instead of after twenty minutes of pushing bytes
at a server that will refuse them. The constant lives in
`TranscriptionService.maxUploadBytes`.

### Timeouts

`timeoutIntervalForRequest` is 300s and `timeoutIntervalForResource` is 3600s.
The defaults would kill exactly the uploads that matter most: a forty-minute
meeting, from a 2017 laptop, on ordinary wifi, followed by server-side
processing.

### Memory

The file is read with `Data(contentsOf:)` and the whole multipart body is held
in memory. For the sizes this app actually sees — a 40-minute MP3 is tens of
megabytes — that is fine. If memory pressure ever shows up on the Intel
machine, the change is to spool the envelope to a temp file and use
`uploadTask(with:fromFile:)`. Test before optimising.

## Testing plan

Iterate upward in size. The multipart envelope either works or it does not, and
finding that out on a ten-second clip is much faster than on a full meeting.

1. 10 seconds, one speaker — proves the envelope, the key, the decoding
2. 2 minutes, two speakers — proves diarization and turn-grouping
3. 15 minutes, three or more speakers — proves timeouts and the scrolling view
4. A real 40+ minute recording, **on Rosy** — proves memory and upload duration

Steps 1–3 can run on the M4. Step 4 has to happen on Rosy; it is the only test
that exercises the actual constraint.

## Not in v1, deliberately

Speaker renaming, Keychain, a settings screen, transcript history, file export,
SRT output, progress percentage, keyterms.

The API key is stored in `UserDefaults`, which means a plist readable by
anything running as your user. That is fine for a first build and worth fixing
before this key is attached to anything expensive.
