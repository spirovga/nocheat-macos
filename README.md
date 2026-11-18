# Human or AI for macOS

The macOS client of **Human or AI**: it listens to a job interview, shows a live transcript of
both sides, and reports how likely the candidate's answers are AI-generated.

This repository is the full source of the app, published so you can check what it does with
your audio and data.

## What the app captures

- **Microphone**: your voice as the interviewer. Echo cancellation is on, so the candidate's voice
  coming out of your speakers is not picked up a second time.
- **System audio**: what this Mac plays, i.e. the candidate's voice in the call. It uses a
  Core Audio process tap and needs only the "System Audio Recording Only" permission.
  Nothing on screen is captured.

Capture runs only between **Start** and **Stop** (`AudioCapture.swift`).

## What is sent, and where

Everything goes to one server: the address in `serverURL` (`AppModel.swift`).

- While listening: both audio streams, as 16 kHz mono PCM, over one websocket (`StreamClient.swift`).
  The server returns the transcript, the AI-probability score and the answer-timing check.
- Your access key or sign-in session, as a bearer token on every request.
- Requests to list or re-evaluate your recent sessions, and to ask for more minutes.

The only other site involved is Google, and only if you choose **Sign in with Google**: the sign-in
page opens in a system browser sheet and ends back at the same server (`GoogleSignIn.swift`).
There is no analytics, no crash reporting and no third-party SDK.

## What is stored on this Mac

In `~/Library/Application Support/Human or AI/`, readable by your user account only (`Credential.swift`):

- `credential`: your access key or sign-in session. Removed when you sign out.
- `history.json`: the transcript, so it survives a restart. Removed by **Clear history** or when you sign out.

**Export chat history** saves the transcript as a text file wherever you choose; it is not sent anywhere.

## Building

Requires macOS 14.4 or later and the Swift toolchain (Xcode or Command Line Tools).

```sh
scripts/build-app.sh      # builds "build/Human or AI.app", ad-hoc signed
```

## Licence

Copyright © 2026 Gregory Spirov. All rights reserved. The source is published so you can read,
build and audit the app; it is not licensed for reuse or redistribution.
