# Rosy Transcribe

A small macOS app that records microphone and system audio—or takes an existing
audio file—and produces a speaker-labelled transcript you can copy in one click. ElevenLabs Scribe works
on every supported Mac; Apple-silicon Macs on macOS 26 or later can instead
transcribe and diarize entirely on-device.

Built for **Rosy** — a 2017 MacBook Retina 12" (Intel Core m3) on macOS Ventura
13.7. That machine cannot run local ML models, which is the whole reason the
transcription happens over an API.

- Deployment target: **macOS 13.0**
- Architecture: **universal (arm64 + x86_64)**
- Dependencies: **Sparkle**, for updates, and **FluidAudio**, for optional
  local speaker diarisation
- App Sandbox: **off** (personal tool, not an App Store submission)
- Signing: self-signed with the local **Rosy Transcribe Local Signing** identity
- Licence: MIT

## What you need

- A Mac running **macOS 13 or later**. Intel or Apple Silicon; the build is
  universal.
- An **ElevenLabs API key**, unless you are on an Apple-silicon Mac running
  macOS 26 and using **On This Mac** for everything. Transcription happens on
  ElevenLabs' servers and is billed per hour of audio, so this is not free to
  run. The app stores the key in your login Keychain and sends it to nobody but
  ElevenLabs.
- **Xcode**, to build it, and a **self-signed code-signing certificate** — see
  [The signing identity](#the-signing-identity). There is no notarised
  download, so a build fetched from a release needs a right-click → Open the
  first time and macOS will be blunt about not recognising the developer.
  Building it yourself avoids that entirely.

A word on what you are uploading. This sends your audio to a third party, so
for confidential recordings — the use this was written for — check ElevenLabs'
retention and training terms against whatever duty of confidentiality you are
  under. Imported audio remains wherever you placed it. Audio recorded by Rosy
  and all transcripts stay in your own Application Support folder.

The optional **On This Mac** engine needs Apple silicon and macOS 26 or later.
It uses Apple's SpeechTranscriber for the words and FluidAudio's native Core ML
diarizer for the speaker timeline. Apple and diarization models download on
first use and are cached thereafter; the recording itself stays on the Mac.
On Intel Macs or older macOS versions the choice is greyed out, with the reason
shown in its help text. ElevenLabs remains available as before.

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

Output lands in `build/RosyTranscribe.app`.

You can also just open `RosyTranscribe.xcodeproj` and hit Run.

### The signing identity

**The project will not build until this certificate exists.** Both app
configurations set `CODE_SIGN_IDENTITY = "Rosy Transcribe Local Signing"`, and
`build.sh` deliberately fails if signing falls back to ad-hoc.

That is not ceremony. macOS grants microphone and screen-recording permission
to a *signature*, and an ad-hoc signature is different on every build — so an
ad-hoc Rosy would ask for both permissions again after every rebuild, and quietly
lose the ability to record until you granted them. A stable local identity makes
the grant stick.

Create it once, in **Keychain Access**:

1. **Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…**
2. Name: `Rosy Transcribe Local Signing` — exactly, it is matched by name.
3. Identity Type: **Self Signed Root**. Certificate Type: **Code Signing**.
4. Create, and leave it in the **login** keychain.

It never leaves your Mac, and it is unrelated to the Sparkle update key — that
one signs *releases*, this one signs *builds*.

## Install on Rosy

Copy `RosyTranscribe.app` across, then **right-click → Open** the first time.
The app is self-signed with a local identity rather than notarised, so a plain
double-click will be refused by Gatekeeper. Once opened this way it launches
normally thereafter, and because the identity is stable the microphone and
screen-recording permissions survive later updates.

## Use

1. Start on **Home** and choose Voice Note, System Audio, Meeting, or Transcribe
   a File. Meeting mode records the microphone and Mac audio separately;
   headphones are strongly recommended to prevent doubled speech.
2. Choose **ElevenLabs** or **On This Mac** in the Transcription menu. On This
   Mac is available only on Apple silicon running macOS 26 or later.
3. For ElevenLabs, open **Settings ▸ Cloud Transcription** — the key button in
   the toolbar goes straight there — and paste your API key. It is stored in the
   Keychain and remembered. The field is masked; **Reveal** shows it. Pressing
   Transcribe with no usable engine opens Settings rather than failing.
4. Pick a language, or leave it on Auto-detect. In local mode, Auto uses the
   Mac's current language because Apple Speech does not auto-detect languages.
   **Expected speakers** appears when On This Mac is selected and the recording
   is not a two-track meeting; set it when the headcount is known. A two-track
   meeting instead asks for **Remote speakers**: choose 1 for a class with one
   student, or the number of people heard through the Mac for a group call.
5. Optionally add key terms — see below. They currently apply to ElevenLabs.
6. Transcribe. Long recordings can take several minutes.
7. Copy All.

The meeting title leads the window, with language beside it. Transcribe,
Copy All and Save as Markdown live together in the right-hand action card,
directly above the People panel.

## How it works

| File | Responsibility |
|---|---|
| `RosyTranscribeApp.swift` | `@main`, a single window |
| `ContentView.swift` | The whole UI, plus the `@MainActor` view model |
| `TranscriptionService.swift` | The API call, timeouts, and error mapping |
| `LocalTranscriptionService.swift` | Apple Speech + Core ML diarization and timeline alignment |
| `MultipartBuilder.swift` | The `multipart/form-data` encoder |
| `Models.swift` | `Codable` structs for the response |
| `TranscriptFormatter.swift` | `words[]` → grouped speaker turns |
| `Keyterms.swift` | Glossary parsing and limits |
| `SpeakerColor.swift` | The speaker palette, free of SwiftUI |
| `TranscriptRecord.swift` | A saved transcript, and the on-disk store |
| `SpeakerEditor.swift` | Reassigning and editing segments, free of UI |
| `TranscriptSearch.swift` | Finding text, free of UI |
| `SegmentTextView.swift` | The editable, selectable, highlightable segment |
| `AudioPlaybackService.swift` | Local playback, seeking, and playhead state |
| `AudioRecordingService.swift` | Separate microphone/system capture, levels, permissions, and local recording storage |
| `SettingsModels.swift` | Settings value types, their JSON stores, and ignored-segment filtering |
| `SettingsView.swift` | The five settings panes |
| `UpdaterService.swift` | Sparkle, behind `canImport` |
| `KeychainStore.swift` | Every secret, and migration off `UserDefaults` |

`TranscriptFormatter`, `MultipartBuilder` and `Keyterms` are free of UI and
networking types, which is what makes them testable without an API key.
`RosyTranscribeTests` covers all three, plus response decoding and the
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

### Local diarization tuning

Local mode keeps moderately short replies and uses FluidAudio's conservative
default clustering sensitivity. **Expected speakers** is an actual upper
bound: when the diarizer creates too many aliases, Rosy compares their
duration-weighted voice embeddings and repeatedly merges the closest pair.
It cannot manufacture a speaker the diarizer missed, but it prevents a known
four-person meeting from becoming fifteen apparent identities.

Two-track meetings have stronger evidence than voice clustering: Rosy already
knows which file came from the microphone and which came from the Mac. With
**Remote speakers** set to 1, it skips diarisation for both tracks, labels the
microphone as `You`, and assigns the complete system track to `Speaker 1`.
With two or more remote people, only the system track is diarised and the
selected count becomes its local clustering target. This prevents one student
from being split into several imaginary identities while preserving group-call
support.

Words are assigned only when a speaker interval overlaps them, or when a tiny
and unambiguous boundary gap is close enough to bridge. Larger or equidistant
gaps remain `Unknown` instead of being attributed to an arbitrary person.

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

## Settings

**Settings** in the sidebar holds five panes. Everything here is per-Mac, not
per-transcript.

**Cloud Transcription** — the ElevenLabs API key, and a switch for whether
ElevenLabs appears in the engine picker at all. Turning it off leaves the key
in place; deleting the key also unregisters the provider. The switch refuses to
turn on without a saved key, since an engine that cannot run is worse than one
that is absent.

**Local Transcription** — whether Apple Speech is available on this Mac, and
why not when it is not. Nothing to configure yet.

Edits here save themselves — there is no Save button for a name, a colour or a
rule, and leaving the pane writes out anything still pending. AI services are
the exception: a base URL is confirmed with **Save**, so a half-typed address
is never stored.

**People** — a directory of the people you actually meet with: a name, a
colour, and one of them marked **You**. In a transcript, the People panel can
link a speaker to someone here, which copies their name and colour across. The
link is a *snapshot*: renaming someone later never rewrites a transcript you
have already saved. The microphone track of a voice note or meeting is
automatically given whoever is marked You.

**Ignored Segments** — phrases to drop when a transcript comes back. Matching is
**whole-segment only** and normalised for case, accents and spacing, so a rule
of `obrigada` hides a segment that is exactly "Obrigada." and leaves
"Obrigada, doutora, mas não" alone. Rules apply at transcription time; the
original turns are kept, and a banner offers **Restore**.

**AI Services** — registration for a DeepSeek or OpenAI-compatible endpoint,
with its key in the Keychain. **This is scaffolding.** Nothing in the app sends
anything to these services yet; registering one makes no request and costs
nothing. HTTP is refused unless the host is local.

## The API key

The key lives in the login Keychain, under service `com.rosy.RosyTranscribe`.
v1 kept it in `UserDefaults` — a plist any process running as you can read —
and `KeychainStore.migrateLegacyKeyIfNeeded()` moves an old key across on
first launch and deletes the plist copy. That migration only removes the copy
once the Keychain write has succeeded, so a failure loses nothing.

AI-service keys live in the same Keychain service, one account per service,
named with that service's UUID. Deleting a service deletes its key with it.

**A Keychain prompt after a rebuild means the signature changed.** macOS ties a
secret to the application that stored it, and identifies the application by its
signature. While the app was ad-hoc signed that happened on *every* build, which
is one of the reasons the project moved to the stable `Rosy Transcribe Local
Signing` identity — see [The signing identity](#the-signing-identity). Click
"Always Allow" if you are asked; if you are asked repeatedly, the build is
falling back to ad-hoc and `build.sh` will say so.

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

The palette is a fixed set of ten colours rather than a free colour well, so
every choice stays legible in both light and dark mode. Most are system
colours, which adapt on their own; burgundy has no system equivalent and is
defined for both appearances by hand, since a true burgundy on a dark
background is barely readable.

`SpeakerColor` is an enum of names with no SwiftUI import; `ContentView` maps
each case to a `Color` in a switch that must be exhaustive, so the palette and
its colours cannot drift apart. **New colours are appended, never inserted** —
saved transcripts store the raw values, so reordering would recolour every
speaker on disk. A test pins them.

### Editing the text

Every segment is live. Click for a caret, drag to select, type to edit —
there is no edit mode to enter or leave.

Press **Return** at the caret to split that segment into two. The new segment
inherits the same speaker, which creates a safe boundary around speech that
diarization embedded inside somebody else's turn; right-click the isolated
segment's speaker name to reassign it. Return at the very start or end does
nothing rather than creating an empty row.

That needs `NSTextView` (`SegmentTextView.swift`), because neither SwiftUI
control can do it. `Text` is selectable but not editable. `TextField` is
editable but cannot render highlighted ranges on macOS 13, so find-and-
highlight would stop working, and each field is its own selection island
anyway. `NSTextView` does all of it at once, and it is also the groundwork for
click-a-word-to-play: it can map a point to a character index, which is what
turning a click into a timestamp will need.

Selection still cannot span two segments — each row is its own text view. Copy
All and the Markdown export are the way to take the whole transcript.

Emptying a segment deletes it, which is how a stray "Uhum." gets removed. If
that leaves two adjacent segments by the same speaker they stay separate in
the data and join on output, exactly as a reassignment does.

### Finding things

⌘F, or the magnifying glass in the toolbar, opens a find bar over the
transcript. Return jumps to the next match, the chevrons step either way, and
Escape closes it.
The current match is solid, the others tinted, and the list scrolls to keep
the current one centred.

Search is case- **and diacritic-insensitive**, which is the part that matters
here: this transcribes Portuguese, and `averbacao` typed in a hurry has to
find `averbação`. Nobody should have to reach for the accent keys mid-search.

It searches segment text, not speaker names.

### Fixing what diarization got wrong

Right-click a speaker's name in the transcript to move that one segment to
another speaker, or to move **all** of that speaker's segments at once — the
fix for one person being split into two. **Add Speaker** in the People panel
creates someone to assign segments to.

Each row in the People panel shows a coloured badge and the name at rest —
the badge carries the speaker's initial, or their number while they are still
unnamed, since "S" for every "Speaker N" identifies nobody. Hovering swaps the
row for a name field, a colour menu and a delete button. The row keeps that
form while the field has focus rather than only while hovered, so nudging the
mouse mid-rename does not pull the field out from under the cursor.

Deleting a speaker never deletes what they said. Their segments are detached
and shown as **Unknown**, and can be handed to anyone with the same
right-click menu. Because of that the panel stays visible even with no
speakers left, or Add Speaker would be unreachable.

Reassignment joins neighbouring segments once they belong to the same speaker.
This keeps bulk cleanup from leaving a ladder of identical speaker rows. A
Return-created split remains separate until a reassignment resolves that
boundary.

**The window is an editor of segments**: every boundary that remains gets its
own row and right-click target. Reassignment resolves newly redundant
boundaries immediately. Markdown and Copy All perform the same final adjacent
speaker cleanup before producing the readable transcript.

## The library

Every transcription is saved automatically, the moment it comes back — a
transcription costs money and minutes, and must survive a crash. The sidebar
lists them newest first; click one to reopen it exactly as it was left, names
and colours included. The toolbar carries the API key, Find, and a button to
start a new transcription; the sidebar collapses with the split-view control
macOS puts there itself.

Edits to the title, a speaker's name, or a speaker's colour are saved on a
1.2-second delay. Writing the whole transcript on every keystroke would be a
lot of file I/O on a 2017 dual-core.

Transcripts live in:

```
~/Library/Application Support/RosyTranscribe/Transcripts/<uuid>.json
```

One pretty-printed JSON file each, rather than a single library file. A write
only ever risks the transcript being written, a file that somehow becomes
unreadable costs one meeting rather than all of them, and any of them can be
opened in a text editor. **The audio is not copied** — the transcript remembers
only its original path, and a library of meeting recordings is a much bigger
thing to look after than a library of text.

### Everything Rosy writes

```
~/Library/Application Support/RosyTranscribe/
├── Transcripts/<uuid>.json                    one saved transcript each
├── Recordings/<uuid>/microphone.caf, system.caf   audio Rosy recorded itself
├── CloudTranscriptionProviders.json
├── People.json
├── IgnoredSegments.json
└── AIServices.json                            metadata only, never keys
```

Every file is written `0600` inside a `0700` directory. These are privileged
meetings; the default world-readable mode is more exposure than they deserve.

Two different kinds of audio, treated differently: a file **you** chose is never
copied, and the transcript only remembers where it was. A recording **Rosy
made** lives in `Recordings/` and stays there. Discarding a recording before
using it deletes it — but after that, nothing cleans up, and deleting a
transcript leaves its audio on disk. If you record meetings regularly, that
folder is worth visiting in Finder now and then.

## Audio playback

When the original recording is still present, the transcript shows play/pause,
a scrubber, elapsed time and duration. The play button beside any segment seeks
to the moment that speaker turn began. **Option-click a word** to seek directly
to that word without taking ordinary click, drag-selection or double-click away
from the text editor.

The app stores only the recording's path, never another copy of the recording.
If the file has been moved or deleted, the transcript remains completely usable
and shows **Playback Unavailable — Audio file not found**. **Relink Audio…**
points the transcript at the file's new location and saves that path immediately.
Older saved transcripts have no audio path or timestamps; they open normally
and can be relinked for whole-file playback.

## Saving as Markdown

**Save as Markdown…** writes the transcript out as:

```markdown
# Title of the meeting

**Clara**
Blablablabla

**Ana**
Blablablabla
```

Speakers become bold lines rather than `Name:` lines, which is what renders
sensibly in a Markdown viewer. A blank title produces no heading rather than
an empty one. **Copy All** still copies plain text in the `Name:` form, which
is what pastes cleanly into a document.

The title defaults to the dropped file's name and is never overwritten once
you have typed one.

## The icon

Rose gold, with a microphone. **A placeholder** until there is a real one. `Tools/make_icon.py` draws it and writes the ten
PNGs of `RosyTranscribe/Assets.xcassets/AppIcon.appiconset`:

```sh
python3 Tools/make_icon.py
```

No image library, because none is needed and the project takes no
dependencies. Every shape is a signed distance function, so a pixel's coverage
comes straight from its distance to the nearest edge — which gives exact
anti-aliasing at every size from one sample per pixel, using only `zlib` and
`struct`. Edit the constants at the top of the script and re-run it to change
the colours or the proportions.

## Updates

The app checks GitHub for a newer build on launch, and on demand from
**Rosy Transcribe ▸ Check for Updates…**. It uses [Sparkle][sparkle], the one
third-party dependency in the project, taken on deliberately: replacing a
running application is hard to get right, and the alternative was hand-rolling
the download, signature check, atomic swap and relaunch — the part where a bug
eats the app.

`UpdaterService.swift` sits behind `#if canImport(Sparkle)`, so the app builds
and runs without the package. Updating is simply absent until it is added.

[sparkle]: https://sparkle-project.org

### First-time setup

The package is already declared in the project, so Xcode resolves it on the
next open. What is left is the signing key, which cannot be committed: it is
the only thing preventing someone else from shipping your users an "update".

1. Build once so Xcode fetches the package, then find `generate_keys` in
   `.build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/` and run
   it. It puts a private key in your login Keychain and prints a public key.
2. Put that public key into the project:

   ```sh
   python3 Tools/set_update_key.py 'the-key-generate_keys-printed'
   ```

   It sets both configurations, tolerates the newlines and spaces that come
   with copying out of a terminal, and re-validates the project file before
   leaving it changed. If the result would not parse it puts the file back
   and says so.

   Not a `sed` one-liner on purpose: the key is base64, so it contains `/`
   and `+` and usually ends in `=`, which fight sed's delimiter and shell
   quoting — and are invalid unquoted inside a project file. Getting that
   wrong yields a project Xcode refuses to open.

   You can also set `SUPublicEDKey` in Xcode's **Build Settings**, which is
   just as safe. Editing `project.pbxproj` by hand is the option to avoid;
   it lives inside the `.xcodeproj` package, which Finder shows as a single
   item — right-click, **Show Package Contents**.

Until step 2 is done Sparkle will refuse every update it is offered, which is
the correct behaviour for an unsigned feed.

The private key never leaves your Keychain. Anyone can read the appcast; only
someone holding that key can publish an update the app will accept.

### Publishing one

```sh
./Tools/release.sh
```

It builds, zips with `ditto` (a plain `zip` mangles an `.app`), signs the zip,
and prints the `<item>` to paste into `appcast.xml`. Then commit the appcast
and create the GitHub release with the zip attached — both halves are needed,
since the appcast is what the app reads and the release is where the file it
names lives.

Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` before running it.
Sparkle orders updates by `CFBundleVersion`, so a build that does not increase
is a build nobody is ever offered.

## Not built yet, deliberately

SRT output, and a progress percentage. The AI Services pane is registered but
unused — see [Settings](#settings).
