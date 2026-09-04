# Scribe

Scribe is a macOS menu bar app that records meetings, transcribes them locally, and saves searchable Markdown notes.

## Features

- Detects Zoom and Arc meetings and offers to record them.
- Captures microphone and system audio as separate tracks.
- Transcribes locally with WhisperKit and labels remote speakers with SpeakerKit.
- Suppresses system-audio bleed from the microphone track while preserving double-talk.
- Generates notes through OpenCode or Pi and stores the notes and transcript as Markdown.
- Organizes notes in an Inbox and user-selected folders.
- Recovers interrupted processing and retries failures.
- Removes raw audio five days after transcription while retaining notes and retryable data.

## Requirements

- macOS 26 or later.
- Xcode with Swift 6.2 or later.
- An Apple Development or Developer ID signing identity for stable permission grants.
- An authenticated [OpenCode](https://opencode.ai/) or [Pi](https://github.com/badlogic/pi-mono) CLI for note generation.

Transcription runs on the Mac. Note generation passes the transcript to the provider configured in the selected CLI.

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

On first use, grant microphone, system audio recording, and notification permissions when macOS requests them. Permission status and Launch at Login are available in Scribe's Settings view.

## Data

Scribe stores its working data under `~/Library/Application Support/Scribe/`:

- `inbox/` contains completed Markdown notes.
- `sessions/` contains crash-recovery metadata, transcripts, and temporary audio.
- `settings.json` contains Places and the selected notes client.

Folders added as Places remain ordinary user-owned folders. Moving a note to a Place moves its Markdown file there.

## Development

```sh
swift test
swift build -Xswiftc -strict-concurrency=complete
CODE_SIGN_IDENTITY=- ./scripts/build-app.sh
```

The build script creates `.build/Scribe.app` and runs the bundle smoke test.
