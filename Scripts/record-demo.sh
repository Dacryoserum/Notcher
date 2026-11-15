#!/bin/bash
# Films the README demo from the app itself: a scripted tour on a staged MacBook screen, with made-up content.
# Output, per language: docs/media[/fr]/demo.mp4 (60 fps), poster.png (the README picture that links to
# the video) and screenshots.
#
# Needs ffmpeg and ImageMagick (brew install ffmpeg imagemagick) and the Screen Recording permission for the terminal that runs it.
# The recording window is parked off the edge of the screen: nothing appears, nothing needs closing.
# Your own Notcher data is never read: the app runs on a scratch folder and its own preferences.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v ffmpeg >/dev/null || { echo "ffmpeg is required: brew install ffmpeg" >&2; exit 1; }
command -v magick >/dev/null || { echo "ImageMagick is required: brew install imagemagick" >&2; exit 1; }
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
    # The whole staged screen with a play button: what the README shows, linked to the video.
    magick "$destination/screen.png" -fill "rgba(0,0,0,0.55)" -stroke "rgba(255,255,255,0.85)" -strokewidth 3 -draw "circle 800,700 800,772" \
        -fill white -stroke none -draw "polygon 778,662 778,738 842,700" "$destination/poster.png"
    rm -rf "$scratch"; trap - EXIT
done
ls -lh docs/media docs/media/fr
