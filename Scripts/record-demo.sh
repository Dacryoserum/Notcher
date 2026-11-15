#!/bin/bash
# Films the README demo from the app itself: a scripted tour on a staged MacBook screen, with made-up content.
# Output, per language: docs/media[/fr]/demo.mp4 (60 fps), demo.gif (33 fps, plays inline in the README)
# and screenshots.
#
# Needs ffmpeg (brew install ffmpeg) and the Screen Recording permission for the terminal that runs it.
# The recording window is parked off the edge of the screen: nothing appears, nothing needs closing.
# Your own Notcher data is never read: the app runs on a scratch folder and its own preferences.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v ffmpeg >/dev/null || { echo "ffmpeg is required: brew install ffmpeg" >&2; exit 1; }
./Scripts/build.sh release >/dev/null
for language in en fr; do
    destination="$PWD/docs/media"; [ "$language" = en ] || destination="$destination/$language"
    mkdir -p "$destination"
    scratch="$(mktemp -d)"
    trap 'rm -rf "$scratch"' EXIT
    mkdir -p "$scratch/data" "$scratch/out"
    echo "Recording ($language), about a minute…"
    NOTCHER_DATA_DIR="$scratch/data" dist/Notcher.app/Contents/MacOS/Notcher --record-demo "$scratch/out/raw.mov" -AppleLanguages "($language)"
    # The master is the staged screen at Retina size, with a frame only when something moved.
    # Published: a constant 60 fps H.264 file.
    ffmpeg -v error -y -i "$scratch/out/raw.mov" -vf "fps=60,scale=1920:-2:flags=lanczos" \
        -c:v libx264 -preset slow -crf 21 -pix_fmt yuv420p -movflags +faststart -an "$destination/demo.mp4"
    for still in screen overview shelf notes agents; do
        [ -f "$scratch/out/$still.png" ] && ffmpeg -v error -y -i "$scratch/out/$still.png" -vf "scale=1600:-2:flags=lanczos" "$destination/$still.png"
    done
    # A GIF plays by itself in the README, where GitHub will not embed a video file from the repository.
    # 100/3 frames a second is the fastest rate a GIF can hold exactly (3 hundredths of a second a frame).
    ffmpeg -v error -y -i "$scratch/out/raw.mov" \
        -vf "fps=100/3,scale=720:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=112:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
        "$destination/demo.gif"
    rm -rf "$scratch"; trap - EXIT
done
ls -lh docs/media docs/media/fr
