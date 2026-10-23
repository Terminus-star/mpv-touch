#!/usr/bin/env bash
# Run mpv with lsfg-vk (Lossless Scaling frame generation) at the lowest multiplier, only when
# it makes sense. Your normal `mpv` is unchanged; use this launcher when you want to try it.
#
#   mpv-touch/scripts/run-lsfg.sh /path/to/video.mkv
#
# Frame generation is skipped, and plain mpv started instead, when:
#   * the panel is below MIN_HZ (the 60 Hz battery mode): 23.976 fps x2 = 47.95 fps does not
#     divide into 60 Hz, which would add judder. smooth-judder.lua covers that mode.
#   * Lossless.dll cannot be read (for example /mnt/windows is not mounted).
#
# Environment (all optional):
#   REFRESH_HZ=60     pretend the panel runs at this rate (testing, or to force a decision)
#   LSFG_DRY_RUN=1    print the decision and the command, start nothing

# Stop on the first error, on unset variables, and on failures inside pipes.
set -euo pipefail

# Work from the mpv-touch folder no matter where the script is called from.
cd "$(dirname "$0")/.."

CONF="$PWD/lsfg/conf.toml"
DLL="/mnt/windows/Program Files (x86)/Steam/steamapps/common/Lossless Scaling/Lossless.dll"
MIN_HZ=100

say() { printf 'run-lsfg: %s\n' "$*" >&2; }

# Current refresh rate of the active display mode, as a whole number. Same method as
# z13-refresh-toggle.sh: kscreen-doctor marks the active mode with '*', and colours its output.
current_refresh() {
    kscreen-doctor -o 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*m//g' \
        | grep -oE '[0-9]+:[0-9]+x[0-9]+@[0-9.]+\*' \
        | head -n 1 \
        | sed -E 's/.*@([0-9]+).*/\1/'
}

# Start mpv (or only describe the command, in dry-run mode).
launch() {
    if [[ -n "${LSFG_DRY_RUN:-}" ]]; then
        printf 'would run:'
        printf ' %q' "$@"
        printf '\n'
        exit 0
    fi
    exec "$@"
}

refresh="${REFRESH_HZ:-$(current_refresh || true)}"

if [[ ! -r "$DLL" ]]; then
    say "Lossless.dll not found (is /mnt/windows mounted?): starting mpv without frame generation"
    launch mpv "$@"
fi

if [[ -z "$refresh" || "$refresh" -lt "$MIN_HZ" ]]; then
    say "panel at ${refresh:-unknown} Hz (below $MIN_HZ): frame generation skipped, smooth-judder handles it"
    launch mpv "$@"
fi

say "panel at $refresh Hz: frame generation x2 on"
# ENABLE_LSFG switches the Vulkan layer on, LSFG_CONFIG points it at this project's config.
# mpv must draw through Vulkan for the layer to see its frames. smooth-judder is turned off
# because it would fight the generated frames over frame timing.
export ENABLE_LSFG=1
export LSFG_CONFIG="$CONF"
launch mpv --gpu-api=vulkan --gpu-context=waylandvk --script-opts=smooth-judder-enabled=no "$@"
