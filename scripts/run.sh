#!/usr/bin/env bash
# Run mpv with the isolated touch setup in mpv-touch/config.
# --config-dir makes mpv ignore ~/.config/mpv completely, so your normal mpv setup
# is untouched. Any arguments (files, URLs, mpv options) are passed straight to mpv.
#
# Usage: mpv-touch/scripts/run.sh /path/to/video.mkv

# Stop on the first error, on unset variables, and on failures inside pipes.
set -euo pipefail

# Work from the mpv-touch folder no matter where the script is called from.
cd "$(dirname "$0")/.."

# exec replaces this shell with mpv, so Ctrl+C and the exit code go straight to mpv.
exec mpv --config-dir="$PWD/config" "$@"
