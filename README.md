# Bubble

An open-source, local-first Loom for macOS.

[![A Bubble recording: a designer walks through a dashboard, her face in the round bubble](media/demo.webp)](media/demo.mp4)

<sub>[Watch it as mp4](media/demo.mp4) (56 s, captions, no sound).</sub>

Press ⌥⇧L, talk, press it again. You get an `.mp4` of your screen with your face in a round
bubble, saved in `~/Movies/Bubble` and copied to your clipboard, ready to paste in Slack or a mail.
Then trim it by editing its words.

## Features

- **Screen + camera bubble.** Records a whole display with your mic, your camera in a round bubble
  you can move and resize, and the computer's sound if you want it. Pause, resume, discard.
- **No account, no limit.** No sign-up, no upload, no time limit, no watermark.
- **Your files, on your disk.** Plain `.mp4` files in a folder you pick. Bubble never changes them.
- **An editor that cuts by the words.** Open a recording in the editor (a page served by Bubble on
  your Mac, in your browser): it transcribes on its own, and the transcript sits next to the video. Select words or a stretch of the
  timeline, then cut it or speed it up. Undo anything. Download the edited video.
- **Transcription on your Mac or with Voxtral.** On this Mac with Apple's on-device speech
  (macOS 26), or with Mistral's Voxtral if you paste your own API key (better words, speakers).

![The Bubble editor: the recording transcribes on its own, two cuts, a slow part at 1.5×, then Download](media/editor.webp)

<sub>The editor on a test recording. [Watch it as mp4](media/editor.mp4).</sub>

## Install

1. Download `Bubble-<version>.zip` from [Releases](https://github.com/gvergnaud/bubble/releases).
2. Unzip it and drag `Bubble.app` to your Applications folder.
3. Open it. At the first recording, macOS asks for Screen Recording, Camera and Microphone.

Needs macOS 15 or later on a Mac with Apple silicon.

**First launch.** This build is signed but not notarized by Apple, so macOS blocks the first launch.
Open it once, then go to **System Settings › Privacy & Security** and click **Open Anyway** next to
"Bubble". Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/Bubble.app`.

## Build from source

You need the Xcode Command Line Tools (Swift 6). Xcode itself is not needed.

```sh
git clone https://github.com/gvergnaud/bubble.git
cd bubble
scripts/build-app.sh release      # -> build/Bubble.app
scripts/check.sh                  # the tests, on synthetic media (no screen, camera or mic)
```

`build-app.sh` signs with your Developer ID or Apple Development identity if you have one, else
ad-hoc. With an ad-hoc signature, macOS forgets the Screen Recording permission at each rebuild.

The code: `Sources/BubbleCore` (capture), `Sources/BubbleUI` (the app), `Sources/BubbleEditor` (the
editor's local server, export and transcription), `web/editor` (the editor page: plain HTML, CSS and
JS, no build step). The design and architecture notes are in `docs/`.

## Privacy

Nothing leaves your Mac, with one exception you turn on yourself: if you paste a Mistral API key and
transcribe with Voxtral, the recording's audio is sent to Mistral's API to be transcribed. The key
stays in your macOS Keychain. No analytics, no telemetry, no account.

The editor's server listens on `127.0.0.1` only, behind a per-install token.

## License

[MIT](LICENSE)

## Credits

Made by [Gabriel Vergnaud](https://github.com/gvergnaud), with a team of AI agents in
[bise](https://bise.dev). Inspired by [Loom](https://www.loom.com). Transcription by Apple's Speech
framework and Mistral's [Voxtral](https://mistral.ai).
