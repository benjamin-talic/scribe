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

Set `CODE_SIGN_IDENTITY` to one of them. Use `CODE_SIGN_IDENTITY=- ./scripts/build-app.sh` for an ad-hoc development build; `install.sh` requires a stable signing identity.

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
