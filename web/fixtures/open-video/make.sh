#!/bin/bash
# Owner: QA track. Makes the tiny fake videos of docs/editor-open-video.md §4 (one per edge case),
# 2 s, 320×180, a test pattern + a sine. Needs ffmpeg (Homebrew) only to regenerate them: the
# files are checked in, the gate never runs this script.
#   web/fixtures/open-video/make.sh
set -euo pipefail
cd "$(dirname "$0")"
command -v ffmpeg >/dev/null || { echo "make.sh: needs ffmpeg (brew install ffmpeg)" >&2; exit 1; }

F=(ffmpeg -hide_banner -loglevel error -y)
V=(-f lavfi -i "testsrc2=size=320x180:rate=30:duration=2")
A=(-f lavfi -i "sine=frequency=440:sample_rate=48000:duration=2")
H264=(-c:v libx264 -preset veryfast -pix_fmt yuv420p -crf 28)
AAC=(-c:a aac -b:a 64k)

# Opens: the plain cases.
"${F[@]}" "${V[@]}" "${A[@]}" "${H264[@]}" "${AAC[@]}" -movflags +faststart h264.mp4
"${F[@]}" "${V[@]}" "${A[@]}" "${H264[@]}" "${AAC[@]}" h264.mov
"${F[@]}" "${V[@]}" "${A[@]}" "${H264[@]}" "${AAC[@]}" h264.m4v
"${F[@]}" "${V[@]}" "${A[@]}" -c:v libx265 -preset veryfast -tag:v hvc1 -pix_fmt yuv420p "${AAC[@]}" hevc.mp4
# Opens, 1 s long: "a different length" for Locate….
"${F[@]}" -f lavfi -i "testsrc2=size=320x180:rate=30:duration=1" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=1" \
  "${H264[@]}" "${AAC[@]}" one-second.mp4
# Opens, no transcript: no sound track.
"${F[@]}" "${V[@]}" "${H264[@]}" no-sound.mp4
# Opens as no sound: a Vorbis sound track AVFoundation doesn't list at all (editor-media, m_789).
"${F[@]}" "${V[@]}" "${A[@]}" "${H264[@]}" -c:a libvorbis -strict experimental vorbis-audio.mp4
# Opens, the browser (Chrome) can't play it: ProRes.
"${F[@]}" "${V[@]}" "${A[@]}" -c:v prores_ks -profile:v 0 -pix_fmt yuv422p10le -c:a pcm_s16le prores.mov
# Opens, not 30 fps: 60, 25 and 24 fps.
"${F[@]}" -f lavfi -i "testsrc2=size=320x180:rate=60:duration=2" "${A[@]}" "${H264[@]}" "${AAC[@]}" p60.mp4
"${F[@]}" -f lavfi -i "testsrc2=size=320x180:rate=25:duration=2" "${A[@]}" "${H264[@]}" "${AAC[@]}" p25.mp4
# Opens, HDR: HEVC 10-bit HLG, tagged like an iPhone clip.
"${F[@]}" "${V[@]}" "${A[@]}" -c:v libx265 -preset veryfast -tag:v hvc1 -pix_fmt yuv420p10le \
  -x265-params "colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc" \
  -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc "${AAC[@]}" hdr-hlg.mov
# Opens, rotated (a portrait phone clip: 180×320 shown).
"${F[@]}" -display_rotation 90 -i h264.mp4 -c copy rotated.mp4
# Opens, two audio tracks.
"${F[@]}" "${V[@]}" "${A[@]}" -f lavfi -i "sine=frequency=880:sample_rate=48000:duration=2" \
  -map 0:v -map 1:a -map 2:a "${H264[@]}" "${AAC[@]}" two-audio.mp4

# Refused: a container Bubble can't open (unsupported_format).
"${F[@]}" "${V[@]}" "${A[@]}" "${H264[@]}" "${AAC[@]}" h264.mkv
"${F[@]}" "${V[@]}" "${A[@]}" -c:v libvpx-vp9 -b:v 200k -c:a libopus clip.webm
# Refused: a codec Bubble can't decode, in an MP4 (unsupported_format, "VP9").
"${F[@]}" "${V[@]}" "${A[@]}" -c:v libvpx-vp9 -b:v 200k "${AAC[@]}" vp9.mp4
# Refused: no video track (no_video).
"${F[@]}" "${A[@]}" "${AAC[@]}" audio-only.m4a
"${F[@]}" "${A[@]}" "${AAC[@]}" audio-only.mp4
# Refused: not a video at all, named like one.
printf 'not a video\n%.0s' {1..64} > not-a-video.mp4

ls -l | awk 'NR > 1 { printf "%8d  %s\n", $5, $9 }'
