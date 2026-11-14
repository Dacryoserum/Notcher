#!/bin/bash
# Builds what a GitHub release needs for the in-app updater:
#   dist/release/Notcher-<version>-macos-<arch>.zip   the app
#   dist/release/SHA256SUMS.txt                       its checksum
#   dist/release/latest.json                          the signed manifest the app reads
#
#   ./Scripts/release.sh --init-key   once: creates the signing key in the keychain and writes its public
#                                     half into Sources/NotcherCore/Updates.swift (commit that change)
#   ./Scripts/release.sh              builds and signs the version of App/Info.plist
#   ./Scripts/release.sh --publish    same, then creates a draft release on GitHub with these files
# Release notes shown in the app come from RELEASE_NOTES.md at the root of the repository, if present.
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
service="fr.notcher.update-signing"
source_file="Sources/NotcherCore/Updates.swift"
repository="Dacryoserum/Notcher"

read_key() { security find-generic-password -s "$service" -w 2>/dev/null || true; }
embedded_key() { sed -n 's/^ *public static let publicKey = "\(.*\)"$/\1/p' "$source_file"; }

mode="${1:-build}"
case "$mode" in build|--publish|--init-key) ;; *) echo "Usage: $0 [--init-key | --publish]" >&2; exit 2;; esac

if [ "$mode" = "--init-key" ]; then
    if [ -n "$(read_key)" ]; then
        echo "A signing key already exists in the keychain ($service). Nothing was changed." >&2
        echo "Its public half: $(NOTCHER_UPDATE_SIGNING_KEY="$(read_key)" swift Scripts/update-tool.swift public)" >&2
        exit 1
    fi
    pair="$(swift Scripts/update-tool.swift keygen)"
    private="$(printf '%s\n' "$pair" | awk '$1 == "private" { print $2 }')"
    public="$(printf '%s\n' "$pair" | awk '$1 == "public" { print $2 }')"
    [ -n "$private" ] && [ -n "$public" ] || { echo "Key generation failed." >&2; exit 1; }
    security add-generic-password -s "$service" -a notcher -l "Notcher update signing key" -w "$private"
    sed -i '' "s|^\( *public static let publicKey = \)\".*\"$|\1\"$public\"|" "$source_file"
    [ "$(embedded_key)" = "$public" ] || { echo "Could not write the public key into $source_file." >&2; exit 1; }
    echo "Signing key stored in the keychain. Public key written to $source_file: $public"
    echo "Keep a copy of the private key somewhere safe (a password manager):"
    echo "    security find-generic-password -s $service -w"
    echo "Without it, installed copies can no longer be updated."
    exit 0
fi

private="${NOTCHER_UPDATE_SIGNING_KEY:-$(read_key)}"
[ -n "$private" ] || { echo "No signing key. Run: $0 --init-key" >&2; exit 1; }
public="$(NOTCHER_UPDATE_SIGNING_KEY="$private" swift Scripts/update-tool.swift public)"
# A release signed with another key would be refused by every installed copy.
[ "$public" = "$(embedded_key)" ] || { echo "The signing key does not match the public key in $source_file." >&2; exit 1; }

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/Info.plist)"
tag="v$version"
case "$(uname -m)" in arm64) platform="macos-arm64";; x86_64) platform="macos-x86_64";; *) echo "Unknown architecture." >&2; exit 1;; esac
if [ "$mode" = "--publish" ]; then
    [ -z "$(git status --porcelain)" ] || { echo "Commit or stash your changes before publishing." >&2; exit 1; }
    gh release view "$tag" --repo "$repository" >/dev/null 2>&1 && { echo "Release $tag already exists. Raise the version in App/Info.plist." >&2; exit 1; }
fi

./Scripts/test.sh
./Scripts/build.sh release
out="$PWD/dist/release"
rm -rf "$out"; mkdir -p "$out"
archive="Notcher-$version-$platform.zip"
# ditto keeps the bundle's permissions, symlinks and signature intact.
ditto -c -k --keepParent dist/Notcher.app "$out/$archive"
(cd "$out" && shasum -a 256 "$archive" > SHA256SUMS.txt)
notes="-"; [ -f RELEASE_NOTES.md ] && notes="RELEASE_NOTES.md"
NOTCHER_UPDATE_SIGNING_KEY="$private" swift Scripts/update-tool.swift manifest "$out/$archive" "$version" "$platform" \
    "https://github.com/$repository/releases/download/$tag/$archive" "$notes" "$out/latest.json"

if [ "$mode" = "--publish" ]; then
    notes_arguments=(--generate-notes); [ -f RELEASE_NOTES.md ] && notes_arguments=(--notes-file RELEASE_NOTES.md)
    gh release create "$tag" "$out/$archive" "$out/SHA256SUMS.txt" "$out/latest.json" --repo "$repository" --draft --title "Notcher $tag" "${notes_arguments[@]}"
    echo "Draft release $tag created. Installed copies see it once you publish it on GitHub."
else
    printf 'Release files ready in %s\n' "$out"
    echo "Publish them with: $0 --publish   (or attach the three files to a release tagged $tag)"
fi
