#!/usr/bin/env bash
# Run the pinned Godot editor without requiring a system-wide installation.
set -euo pipefail

if [[ -n "${WORLDSMITH_GODOT:-}" ]]; then
    godot_binary="$WORLDSMITH_GODOT"
elif command -v godot >/dev/null 2>&1; then
    godot_binary="$(command -v godot)"
elif command -v godot4 >/dev/null 2>&1; then
    godot_binary="$(command -v godot4)"
elif [[ -x /Applications/Godot.app/Contents/MacOS/Godot ]]; then
    godot_binary=/Applications/Godot.app/Contents/MacOS/Godot
elif [[ -x /tmp/worldsmith-tools/Godot.app/Contents/MacOS/Godot ]]; then
    # The initial development download is available on this workstation.
    godot_binary=/tmp/worldsmith-tools/Godot.app/Contents/MacOS/Godot
elif [[ "$(uname -s)" == Darwin ]]; then
    cache_dir="${HOME}/Library/Caches/Worldsmith"
    app_dir="${cache_dir}/Godot-4.6.3.app"
    godot_binary="${app_dir}/Contents/MacOS/Godot"
    if [[ ! -x "$godot_binary" ]]; then
        mkdir -p "$cache_dir"
        download_dir="$(mktemp -d "${cache_dir}/download.XXXXXX")"
        trap 'rm -rf "$download_dir"' EXIT
        archive="${download_dir}/Godot.zip"
        url="https://github.com/godotengine/godot/releases/download/4.6.3-stable/Godot_v4.6.3-stable_macos.universal.zip"
        echo "Downloading Godot 4.6.3 to ${cache_dir}..." >&2
        curl -fL --retry 3 --output "$archive" "$url"
        expected="30630f3e9b11e10b35c1f90ba8814185dcec43fae1a48345159be7552c64bfe8"
        actual="$(shasum -a 256 "$archive" | cut -d ' ' -f 1)"
        if [[ "$actual" != "$expected" ]]; then
            echo "Godot download checksum mismatch" >&2
            exit 1
        fi
        unzip -q "$archive" -d "$download_dir"
        mv "${download_dir}/Godot.app" "$app_dir"
        rm -rf "$download_dir"
        trap - EXIT
    fi
else
    echo "Godot 4.6 is not installed. Install it or set WORLDSMITH_GODOT to its executable." >&2
    exit 1
fi

exec "$godot_binary" "$@"
