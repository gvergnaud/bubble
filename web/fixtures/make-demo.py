#!/usr/bin/env python3
"""Builds the editor fixture: web/fixtures/demo.mp4 + demo.project.json + demo.waveform.json.

Owner: architect (contract: docs/editor-api.md). Offline and silent: macOS `say -o` writes speech
to files (nothing plays), ffmpeg muxes it with a test pattern. Word timings are estimated inside
each sentence (proportional to letters), sentence and turn boundaries are exact: good to within
~0.1 s, which is what a transcript engine gives anyway.

    python3 web/fixtures/make-demo.py
"""
import json, os, re, subprocess, tempfile, wave, struct, base64

HERE = os.path.dirname(os.path.abspath(__file__))
FILLERS = {"uh", "um", "uhm", "euh", "hmm", "erm"}

# (speaker, voice, sentences). Two people, a few fillers, one long boring stretch to cut or speed up.
SCRIPT = [
    ("S1", "Samantha", [
        "Hey everybody, uh, I'm Gabriel, and this is a quick demo of Bubble.",
        "Bubble is a tiny screen recorder for the Mac, and, um, everything stays on your machine.",
        "You press Option Shift L, you talk, you press it again, and the video is in your Movies folder.",
    ]),
    ("S2", "Daniel", [
        "So wait, there is no account and no upload at all?",
        "Uh, how do I send the video to someone then?",
    ]),
    ("S1", "Samantha", [
        "Right, no account. The file is on your clipboard when you stop, so you just paste it in Slack.",
        "Now, um, let me show you the editor, which is the new part.",
        "On the right you have the transcript, with every word linked to the video.",
        "If I select a sentence and press delete, the sentence is struck through and that part is cut from the video.",
        "This next bit is honestly a bit slow, I'm just scrolling through the settings, uh, one by one, to show that nothing is hidden, and there is really not much to see here.",
        "So I can select it and play it at one and a half speed instead of cutting it.",
    ]),
    ("S2", "Daniel", [
        "And the original recording is never changed?",
    ]),
    ("S1", "Samantha", [
        "Never. The edits live next to it, and you download a new file when you're done.",
        "Okay, that's it, uh, thanks for watching.",
    ]),
]

PAUSE_SENTENCE = 0.35
PAUSE_TURN = 0.9


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def duration(path):
    return float(run("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path))


def main():
    tmp = tempfile.mkdtemp(prefix="bubble-fixture-")
    parts, words, t = [], [], 0.6  # start with a short silence
    silence_head = os.path.join(tmp, "head.wav")
    run("ffmpeg", "-v", "error", "-f", "lavfi", "-i", f"anullsrc=r=48000:cl=mono", "-t", f"{t}", silence_head)
    parts.append(silence_head)
    n = 0
    for turn, (speaker, voice, sentences) in enumerate(SCRIPT):
        for i, sentence in enumerate(sentences):
            aiff = os.path.join(tmp, f"s{n}.aiff")
            wav = os.path.join(tmp, f"s{n}.wav")
            run("say", "-v", voice, "-r", "185", "-o", aiff, sentence)
            run("ffmpeg", "-v", "error", "-i", aiff, "-ar", "48000", "-ac", "1", wav)
            d = duration(wav)
            # `say` pads ~0.1 s at both ends: spread words over the inner part.
            inner_start, inner_end = t + 0.08, t + d - 0.1
            tokens = sentence.split()
            weights = [max(2, len(re.sub(r"[^\w']", "", w))) + 1 for w in tokens]
            total = sum(weights)
            cursor = inner_start
            for tok, w in zip(tokens, weights):
                span = (inner_end - inner_start) * w / total
                bare = re.sub(r"[^\w']", "", tok).lower()
                word = {"start": round(cursor, 3), "end": round(cursor + span * 0.9, 3), "text": tok, "speaker": speaker}
                if bare in FILLERS:
                    word["filler"] = True
                words.append(word)
                cursor += span
            parts.append(wav)
            t += d
            last_in_turn = i == len(sentences) - 1
            gap = PAUSE_TURN if last_in_turn else PAUSE_SENTENCE
            sil = os.path.join(tmp, f"gap{n}.wav")
            run("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono", "-t", f"{gap}", sil)
            parts.append(sil)
            t += gap
            n += 1

    concat = os.path.join(tmp, "list.txt")
    with open(concat, "w") as f:
        f.writelines(f"file '{p}'\n" for p in parts)
    audio = os.path.join(tmp, "audio.wav")
    run("ffmpeg", "-v", "error", "-f", "concat", "-safe", "0", "-i", concat, "-c:a", "pcm_s16le", audio)
    total = duration(audio)

    mp4 = os.path.join(HERE, "demo.mp4")
    run("ffmpeg", "-v", "error", "-y",
        "-f", "lavfi", "-i", f"testsrc=size=1280x720:rate=30:duration={total}",
        "-i", audio,
        "-vf", "drawtext=text='Bubble fixture %{pts\\:hms}':x=40:y=40:fontsize=48:fontcolor=white:box=1:boxcolor=black@0.6",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-profile:v", "high", "-crf", "30", "-g", "60",
        "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", "-shortest", mp4)

    # Waveform: peak of |sample| per 1/50 s, 0..1, as uint8 base64 (what the server sends).
    pps = 50
    with wave.open(audio) as w:
        rate, frames = w.getframerate(), w.readframes(w.getnframes())
    samples = struct.unpack(f"<{len(frames) // 2}h", frames)
    step = rate // pps
    peaks = [min(255, int(max((abs(s) for s in samples[i:i + step]), default=0) / 32768 * 255 * 1.4))
             for i in range(0, len(samples), step)]
    with open(os.path.join(HERE, "demo.waveform.json"), "w") as f:
        json.dump({"peaksPerSecond": pps, "encoding": "uint8-base64", "peaks": base64.b64encode(bytes(peaks)).decode()}, f)

    # A few edits so every state shows: a filler cut, a sentence cut, a 1.5x stretch.
    def phrase(first, last):
        """The words of the sentence that starts with `first` and ends with `last` (exact texts)."""
        texts = [w["text"] for w in words]
        i = next(k for k in range(len(texts)) if " ".join(texts[k:k + len(first.split())]) == first)
        j = next(k for k in range(i, len(texts)) if texts[k] == last)
        return words[i], words[j]

    slow_start, slow_end = (w[k] for w, k in zip(phrase("This next bit", "here."), ("start", "end")))
    cut_start, cut_end = (w[k] for w, k in zip(phrase("So wait,", "all?"), ("start", "end")))
    filler = phrase("um,", "um,")[0]
    segments = sorted([
        {"start": round(filler["start"] - 0.02, 3), "end": round(filler["end"] + 0.02, 3), "rate": 0},
        {"start": round(cut_start - 0.05, 3), "end": round(cut_end + 0.05, 3), "rate": 0},
        {"start": round(slow_start - 0.05, 3), "end": round(slow_end + 0.05, 3), "rate": 1.5},
    ], key=lambda s: s["start"])

    project = {
        "id": "demo",
        "title": "Bubble demo",
        "createdAt": "2026-11-06T14:22:05Z",
        "updatedAt": "2026-11-06T14:40:00Z",
        "video": {"url": "/media/demo/source", "duration": round(total, 3), "width": 1280, "height": 720, "fps": 30,
                  "posterUrl": "/media/demo/poster.jpg"},
        "waveform": {"url": "/api/projects/demo/waveform"},
        "transcript": {
            "status": "ready", "progress": 1, "engine": "fixture", "language": "en",
            "speakers": [{"id": "S1", "name": "Gabriel"}, {"id": "S2", "name": "Speaker 2"}],
            "words": words,
        },
        "edits": {"revision": 3, "segments": segments},
        "export": None,
    }
    with open(os.path.join(HERE, "demo.project.json"), "w") as f:
        json.dump(project, f, indent=1)
    print(f"demo.mp4 {total:.2f} s, {len(words)} words, {len(segments)} edits")


if __name__ == "__main__":
    main()
