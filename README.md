# Scribe

Scribe is a macOS menu bar app that records meetings, transcribes them locally, and saves searchable Markdown notes.

## Features

- Detects Zoom and Arc meetings and shows a floating toast with a prominent Start recording button.
- Start/Stop Recording is also available in the menu bar for keyboard and VoiceOver access. Scribe records one meeting at a time; to switch to another already-active meeting, stop the current recording and start the next from the menu bar.
- Captures microphone and system audio as separate tracks.
- Transcribes locally with WhisperKit and labels remote speakers with SpeakerKit.
- Suppresses system-audio bleed from the microphone track while preserving double-talk.
- Generates notes through Claude (Sonnet by default), OpenCode, or Pi and stores the notes and transcript as Markdown.
- Organizes notes in an Inbox and user-selected folders.
- Deletes notes and remaining recording data to macOS Trash.
- Opens notes in an app of your choice, selected in Settings.
- Recovers interrupted processing and retries failures.
- Removes raw audio five days after transcription while retaining notes and retryable data.
- Dictates to the clipboard: toggle from the menu bar (**Dictate**) or a configurable global shortcut (default `⇧⌘D`, changeable in Settings). Records from the selected microphone only, transcribes locally with WhisperKit, and copies the plain recognized text to the clipboard — no timestamps, speaker labels, notes, or auto-paste. Output preserves your actual words and meaning: no paraphrasing, polishing, grammar rewrites, or summarizing. Punctuation/case pass through exactly as WhisperKit produces them; only whitespace is normalized — no words, including filler, acronyms, or repetitions and self-corrections, are ever removed. A floating indicator shows Stop/Cancel, transcribing progress, and a copied/failed result; it never steals focus from your current app. Cancelling, or an empty/failed transcription, leaves the clipboard untouched. Dictation and meeting recording are mutually exclusive — stop one to start the other.
  - The WhisperKit model stays warm in memory between dictations (starting to load as soon as recording begins, in the background) instead of reloading on every Stop, and unloads itself after five minutes of no dictation activity, or immediately on Quit. Load, queue-wait, decode, and stop-to-clipboard timings are logged to the unified log (`log stream --predicate 'subsystem == "local.scribe.dictation"'`) as durations only — never audio, transcript text, or file paths.

## Requirements

- macOS 26 or later.
- Xcode with Swift 6.2 or later.
- An Apple Development or Developer ID signing identity for stable permission grants.
- An authenticated [Claude Code](https://claude.ai/code), [OpenCode](https://opencode.ai/), or [Pi](https://github.com/badlogic/pi-mono) CLI for note generation.

Transcription runs on the Mac. Note generation passes the transcript to the provider configured in the selected CLI.
Claude uses your existing CLI login with the `sonnet` model alias, without tools or session persistence. Existing installations retain their selected notes client; choose Claude in Settings to switch.

## Install

Clone the repository, then run:

```sh
CODE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/install.sh
open -a /Applications/Scribe.app
```

Find available signing identities with:

```sh
security find-identity -v -p codesigning
```

Set `CODE_SIGN_IDENTITY` to one of them, or put `CODE_SIGN_IDENTITY="..."` in a gitignored `.env` at the repo root. Use `CODE_SIGN_IDENTITY=- ./scripts/build-app.sh` for an ad-hoc development build; `install.sh` requires a stable signing identity.

On first use, grant microphone and system audio recording permissions when macOS requests them. Permission status and Launch at Login are available in Scribe's Settings view. Meeting toasts do not require notification permission.

## Release

```sh
xcrun notarytool store-credentials scribe --apple-id you@example.com --team-id TEAMID  # once
./scripts/release.sh
gh release create vX.Y.Z .build/Scribe.zip
```

`release.sh` builds with the `CODE_SIGN_IDENTITY` you set, notarizes, staples the ticket and writes `.build/Scribe.zip`.

## Data

Scribe stores its working data under `~/Library/Application Support/Scribe/`:

- `inbox/` contains completed Markdown notes.
- `sessions/` contains crash-recovery metadata, transcripts, and temporary audio.
- `settings.json` contains Places and the selected notes client.

Folders added as Places remain ordinary user-owned folders. Moving a note to a Place moves its Markdown file there.
The trash button moves the Markdown file and any remaining session folder to macOS Trash. You can restore the Markdown file to the Inbox or a Place to bring the note back. The preferred note-opening app is saved in macOS user defaults; Reset returns to the system default for Markdown files.

## Development

```sh
swift test
swift build -Xswiftc -strict-concurrency=complete
CODE_SIGN_IDENTITY=- ./scripts/build-app.sh
```

The build script creates `.build/Scribe.app` and runs the bundle smoke test.

`swift test` never touches a real WhisperKit model. To compare the old per-operation load+decode+unload path against the actual production dictation path (real `AppState`/`DictationController`/`DictationModelCache`, prewarmed while a simulated recording is "in progress") with the real "small" model:

```sh
say -o fixture.aiff "The quick brown fox jumps over the lazy dog."
afconvert fixture.aiff fixture.caf -d LEI16@16000 -c 1
afinfo fixture.caf   # note the duration for SCRIBE_DICTATION_BENCHMARK_LEAD_SECONDS below

SCRIBE_DICTATION_BENCHMARK=1 \
SCRIBE_DICTATION_BENCHMARK_FIXTURE="$PWD/fixture.caf" \
SCRIBE_DICTATION_BENCHMARK_LEAD_SECONDS=13.159 \
SCRIBE_DICTATION_BENCHMARK_SAMPLES=5 \
SCRIBE_DICTATION_BENCHMARK_REFERENCE_TEXT="The quick brown fox jumps over the lazy dog." \
swift test --filter DictationBenchmark
```

`SAMPLES` (default 5) and `LEAD_SECONDS` (default 13.159) are optional; `REFERENCE_TEXT` is optional too — without it, recognized text is still printed but accuracy is reported as unchecked rather than silently skipped. Prints old-path and production-path timings per sample plus a recognized-text comparison; see the file header in `Tests/ScribeTests/DictationBenchmark.swift` for what each number means and its OS-cache-state caveats.
