#!/bin/bash
# Records the README demo from the app itself: a scripted tour on a fake desktop, with made-up content.
# Output, per language: docs/media[/fr]/demo.mp4, demo.gif and screenshots.
# Needs ffmpeg (brew install ffmpeg). Your own Notcher data is never read: the app runs on a scratch folder.
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
    echo "Recording ($language)…"
    NOTCHER_DATA_DIR="$scratch/data" dist/Notcher.app/Contents/MacOS/Notcher --record-demo "$scratch/out/raw.mp4" -AppleLanguages "($language)"
    # Small, streamable MP4 for GitHub; a GIF that plays inline in the README.
    ffmpeg -v error -y -i "$scratch/out/raw.mp4" -c:v libx264 -preset slow -crf 23 -pix_fmt yuv420p -movflags +faststart -an "$destination/demo.mp4"
    ffmpeg -v error -y -i "$scratch/out/raw.mp4" -vf "fps=15,scale=800:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=160:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" "$destination/demo.gif"
    for still in overview shelf notes agents headphones; do
        [ -f "$scratch/out/$still.png" ] && cp "$scratch/out/$still.png" "$destination/$still.png"
    done
    rm -rf "$scratch"; trap - EXIT
done
ls -lh docs/media docs/media/fr
