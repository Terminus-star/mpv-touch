#!/usr/bin/env bash
# hdr-ab: flip between SDR mode and HDR mode a few times so the two can be compared by eye.
#
# Why it exists: comparing the modes means toggling HDR, and toggling it can reset related
# settings (wide colour gamut, the HDR colour profile source), so a hand-made A/B quietly compares
# the wrong thing. This script reads your HDR settings first, and re-applies exactly those every
# time it switches HDR back on. It ends in the mode it started in (HDR on).
#
# Usage:
#   hdr-ab.sh [-g GAMUT] [CYCLES] [SECONDS]
#     -g GAMUT   set "sRGB color intensity" (0-100) first, so a candidate value can be judged
#     CYCLES     how many SDR->HDR rounds (default 3)
#     SECONDS    how long each mode stays on screen (default 8; the backlight takes a second or
#                two to settle after each switch)
#
# Start it with HDR already on. Each switch blanks the screen for about a second.
# It says which mode is showing both in the terminal and as a desktop notification (one popup that
# updates in place), so it can be started from KRunner (Alt+Space, then the full path) or a shortcut.
#
# Environment: BRIGHTNESS_OUTPUT  output name for kscreen-doctor (default: eDP-1)
#              HDR_AB_NOTIFY=0    no desktop notifications (terminal output only)
set -u

OUTPUT="${BRIGHTNESS_OUTPUT:-eDP-1}"
GAMUT=""

while getopts "g:" opt; do
    case "$opt" in
    g) GAMUT="$OPTARG" ;;
    *) sed -n '2,21p' "$0" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
CYCLES="${1:-3}"
SECONDS_EACH="${2:-8}"

log() { printf 'hdr-ab: %s\n' "$*" >&2; }

# Desktop notifications, so the script can be run outside a terminal (KRunner, a shortcut) and still
# say which mode is showing. One popup is updated in place (notify-send -r) instead of stacking up.
# HDR_AB_NOTIFY=0 turns them off.
NOTIFY_ID=""
notify() {   # notify TITLE [BODY]
    [ "${HDR_AB_NOTIFY:-1}" = 1 ] || return 0
    command -v notify-send >/dev/null 2>&1 || return 0
    local args=(-a "HDR/SDR compare" -e -t 9000 -p)
    [ -n "$NOTIFY_ID" ] && args+=(-r "$NOTIFY_ID")
    NOTIFY_ID="$(notify-send "${args[@]}" "$1" "${2:-}" 2>/dev/null)" || NOTIFY_ID=""
}

# say TITLE [BODY]: print to the terminal and show a notification
say() {
    log "$1${2:+ - $2}"
    notify "$1" "${2:-}"
}

# the brightness slider as a whole percentage, for the notification text
slider_pct() {
    local now max
    now="$(busctl --user get-property org.kde.ScreenBrightness /org/kde/ScreenBrightness/display0 org.kde.ScreenBrightness.Display Brightness 2>/dev/null | awk '{print $2}')"
    max="$(busctl --user get-property org.kde.ScreenBrightness /org/kde/ScreenBrightness/display0 org.kde.ScreenBrightness.Display MaxBrightness 2>/dev/null | awk '{print $2}')"
    [ -n "$now" ] && [ -n "$max" ] && echo $(( (now * 100 + max / 2) / max )) || echo "?"
}

# KDE pins the laptop backlight at 100% in HDR mode and does NOT put it back to the slider value
# when HDR is switched off (measured: it stayed at 100% for 15 s), so SDR mode would show at full
# brightness, a huge jump that ruins the comparison. slider-reapply.sh makes KDE apply the slider
# again and verifies that the real backlight followed (see that script for why it is not a one-liner).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
reapply_slider() {
    "$HERE/slider-reapply.sh" || say "Warning" "The backlight did not follow the slider; SDR will look too bright."
}

# one reading of the display settings, with colour codes removed
read_state() {
    kscreen-doctor -o | sed 's/\x1b\[[0-9;]*m//g'
}

# field LABEL -> the text after "LABEL: " on the first matching line
field() {
    awk -F': *' -v label="$1" '$1 ~ label { print $2; exit }' <<<"$STATE"
}

STATE="$(read_state)"
HDR_NOW="$(field '^[[:space:]]*HDR$')"
if [ "$HDR_NOW" != "enabled" ]; then
    say "HDR is off" "Turn HDR on first; this comparison ends in HDR mode."
    exit 1
fi

WCG="$(field 'Wide Color Gamut')"
SOURCE="$(field 'HDR color profile source')"
NITS="$(field 'SDR brightness' | sed 's/ nits//')"
if [ -z "$GAMUT" ]; then
    GAMUT="$(field 'SDR gamut wideness' | sed 's/%//')"
fi
case "$WCG" in enabled) WCG_ARG=enable ;; *) WCG_ARG=disable ;; esac

HDR_ON_ARGS=(
    "output.$OUTPUT.hdr.enable"
    "output.$OUTPUT.wcg.$WCG_ARG"
    "output.$OUTPUT.hdrColorProfileSource.$SOURCE"
    "output.$OUTPUT.sdrGamut.$GAMUT"
    "output.$OUTPUT.sdr-brightness.$NITS"
)
log "starting state: HDR on, wide gamut $WCG, source $SOURCE, intensity ${GAMUT}%, white level ${NITS}"

# HDR_AB_DRY=1 prints what would be re-applied and stops, without touching the display
if [ "${HDR_AB_DRY:-}" = 1 ]; then
    printf 'would re-apply: kscreen-doctor %s\n' "${HDR_ON_ARGS[*]}"
    exit 0
fi

# always leave HDR on with the settings we read, even if interrupted
restore() {
    kscreen-doctor "${HDR_ON_ARGS[@]}" >/dev/null 2>&1
    say "Comparison finished" "Back in HDR mode with your settings."
}
trap restore EXIT

# apply the candidate intensity before the first comparison
kscreen-doctor "output.$OUTPUT.sdrGamut.$GAMUT" >/dev/null 2>&1

say "Comparing SDR and HDR" "$CYCLES round(s) of ${SECONDS_EACH}s each, SDR first. Slider $(slider_pct)%, colour intensity ${GAMUT}%."

for ((i = 1; i <= CYCLES; i++)); do
    kscreen-doctor "output.$OUTPUT.hdr.disable" >/dev/null 2>&1
    sleep 1          # let the mode switch finish before touching the slider
    reapply_slider
    say "SDR mode  [$i/$CYCLES]" "Backlight at the slider's $(slider_pct)%."
    sleep "$SECONDS_EACH"
    kscreen-doctor "${HDR_ON_ARGS[@]}" >/dev/null 2>&1
    say "HDR mode  [$i/$CYCLES]" "Your HDR settings, white level ${NITS} nits at the slider's $(slider_pct)%."
    sleep "$SECONDS_EACH"
done
