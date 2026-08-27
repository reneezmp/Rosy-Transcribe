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

1. Paste your ElevenLabs API key into the field at the top. It is stored in
   the Keychain and remembered. The field is masked; the eye button reveals it.
2. Pick a language, or leave it on Auto-detect.
3. Optionally add key terms — see below. They are remembered too.
4. Drop an audio file on the drop zone, or click it to pick one.
5. Transcribe. Long recordings take several minutes — most of it is upload.
6. Copy All.

## How it works

| File | Responsibility |
|---|---|
| `ScribeDropletApp.swift` | `@main`, a single window |
| `ContentView.swift` | The whole UI, plus the `@MainActor` view model |
| `TranscriptionService.swift` | The API call, timeouts, and error mapping |
| `MultipartBuilder.swift` | The `multipart/form-data` encoder |
| `Models.swift` | `Codable` structs for the response |
| `TranscriptFormatter.swift` | `words[]` → grouped speaker turns |
| `Keyterms.swift` | Glossary parsing and limits |
| `SpeakerColor.swift` | The speaker palette, free of SwiftUI |
| `TranscriptRecord.swift` | A saved transcript, and the on-disk store |
| `SpeakerEditor.swift` | Reassigning segments, free of UI |
| `KeychainStore.swift` | The API key, and migration off `UserDefaults` |

`TranscriptFormatter`, `MultipartBuilder` and `Keyterms` are free of UI and
networking types, which is what makes them testable without an API key.
`ScribeDropletTests` covers all three, plus response decoding and the
HTTP-status → message mapping.

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
keyterms                one part per term, repeating the field name
                        (omitted entirely when the glossary is empty)
```

An array parameter goes over multipart as the **same field name repeated**,
one part per value — not as a JSON array in a single part. Sending
`["proferida","averbação",...]` as one field made the server measure the whole
85-character array as a single keyword and reject the request with
`All keywords must be less than 50 characters`. `MultipartField` exists
precisely because a `[String: String]` cannot express a repeated name.

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

## The API key

The key lives in the login Keychain, under service `com.rosy.ScribeDroplet`.
v1 kept it in `UserDefaults` — a plist any process running as you can read —
and `KeychainStore.migrateLegacyKeyIfNeeded()` moves an old key across on
first launch and deletes the plist copy. That migration only removes the copy
once the Keychain write has succeeded, so a failure loses nothing.

**Expect a Keychain prompt after each rebuild.** The app is ad-hoc signed, so
its signature changes every time you build it, and macOS treats each build as
a different application asking for the same secret. Click "Always Allow" and
it will stay quiet until the next build. This is a consequence of not having a
paid Developer Program identity, not a bug.

## Key terms

The API accepts up to 100 terms to bias recognition, which is worth using for
proper nouns and specialised vocabulary. Scribe will otherwise hear the common
word rather than the right one — a legal decision is *proferida*, handed down,
but it comes back as *preferida*, preferred, which is a real word in a
plausible place and therefore easy to miss when proofreading.

Type them separated by commas or newlines. Limits are enforced before the
upload starts rather than after: at most 100 terms, each **under** 50
characters and at most 5 words.

The docs say "≤50 chars", but the server rejects with "All keywords must be
less than 50 characters", so the limit is exclusive. Where the two disagree,
the API wins.

## Speakers

The transcript is laid out in two columns: the speaker on the left, coloured,
and what they said on the right. After a transcription a **People** panel
appears listing each speaker found, in order of first appearance, with a text
field to name them and a swatch to recolour them.

Everyone starts as "Speaker 1", "Speaker 2", … — the API's own numbering,
one-indexed. Typing a name updates the transcript and Copy All immediately.
Clearing the field returns that speaker to its numbered label rather than
leaving a nameless row.

**Names are per transcript and reset with each new file.** The API assigns
`speaker_0`, `speaker_1`, … by order of first appearance, so `speaker_0` is
whoever happens to talk first in that particular recording. Carrying names
across files would mislabel more often than it helped.

The palette is a fixed set of eight system colours rather than a free colour
well, so every choice stays legible in both light and dark mode.
`SpeakerColor` is an enum of names with no SwiftUI import; `ContentView` maps
each case to a `Color` in a switch that must be exhaustive, so the palette and
its colours cannot drift apart.

### Fixing what diarization got wrong

Right-click a speaker's name in the transcript to move that one segment to
another speaker, or to move **all** of that speaker's segments at once — the
fix for one person being split into two. **Add Speaker** in the People panel
creates someone to assign segments to; a speaker who owns no segments can be
removed again from their right-click menu.

Reassignment never merges or deletes a segment. That is what makes it
reversible: physically merging a moved segment into its neighbours would
destroy the boundary and leave no way to put it back.

So the window and the exported file show the same transcript differently, on
purpose. **The window is an editor of segments**: every segment gets its own
row with the speaker's name repeated, even where the row above has the same
speaker, because each row is separately right-clickable and a blank name would
both hide that and misrepresent two segments as one. **The exported file is
for reading**: `TranscriptFormatter.merged` joins adjacent segments by the
same speaker there, so Markdown and Copy All give one block of speech under
one name.

## The library

Every transcription is saved automatically, the moment it comes back — a
transcription costs money and minutes, and must survive a crash. The sidebar
lists them newest first; click one to reopen it exactly as it was left, names
and colours included. The toolbar has a toggle to collapse the sidebar and a
button to start a new transcription.

Edits to the title, a speaker's name, or a speaker's colour are saved on a
1.2-second delay. Writing the whole transcript on every keystroke would be a
lot of file I/O on a 2017 dual-core.

Transcripts live in:

```
~/Library/Application Support/ScribeDroplet/Transcripts/<uuid>.json
```

One pretty-printed JSON file each, rather than a single library file. A write
only ever risks the transcript being written, a file that somehow becomes
unreadable costs one meeting rather than all of them, and any of them can be
opened in a text editor. **The audio is not kept** — this app never opens it,
and a library of meeting recordings is a much bigger thing to look after than
a library of text.

## Saving as Markdown

**Save as Markdown…** writes the transcript out as:

```markdown
# Title of the meeting

**Renée**
Blablablabla

**Lilian**
Blablablabla
```

Speakers become bold lines rather than `Name:` lines, which is what renders
sensibly in a Markdown viewer. A blank title produces no heading rather than
an empty one. **Copy All** still copies plain text in the `Name:` form, which
is what pastes cleanly into a document.

The title defaults to the dropped file's name and is never overwritten once
you have typed one.

## The icon

Rose gold, with a microphone. `Tools/make_icon.py` draws it and writes the ten
PNGs of `ScribeDroplet/Assets.xcassets/AppIcon.appiconset`:

```sh
python3 Tools/make_icon.py
```

No image library, because none is needed and the project takes no
dependencies. Every shape is a signed distance function, so a pixel's coverage
comes straight from its distance to the nearest edge — which gives exact
anti-aliasing at every size from one sample per pixel, using only `zlib` and
`struct`. Edit the constants at the top of the script and re-run it to change
the colours or the proportions.

## Not in v1 or v2, deliberately

A settings screen, SRT output, progress percentage, audio playback.
