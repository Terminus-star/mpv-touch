#!/usr/bin/env bash
# slider-reapply: make KDE apply the brightness slider to the real backlight again, and check it did.
#
# Why it is needed (measured on this laptop, see docs/learning-notes.md):
#   In HDR mode KDE pins the laptop backlight at 100 %. When HDR is switched off it does NOT put the
#   backlight back to the slider's value, so SDR mode runs at full brightness until the slider is
#   touched. Re-sending the same value is ignored, so this script sends a small dip and then the real
#   value. Two calls a few milliseconds apart are sometimes coalesced and do nothing (it worked in 1 of
#   3 tries when tested), so each step is spaced out and the result is VERIFIED against the real
#   backlight, with up to 3 attempts.
#
# Use it only in SDR mode (in HDR mode the backlight is meant to be at 100 %).
#
# Usage:  slider-reapply.sh        exit 0 when the backlight matches the slider, 1 if it never did
set -u

SB=org.kde.ScreenBrightness
SBPATH=/org/kde/ScreenBrightness/display0
SBIFACE=org.kde.ScreenBrightness.Display
BL=/sys/class/backlight/amdgpu_bl1

DIP=200          # how far to dip, in KDE slider units (of 10000): 2 %
SETTLE=0.6       # seconds to let KDE act after each call
TOLERANCE_PCT=3  # the backlight counts as matching when within this many percent of full scale

log() { printf 'slider-reapply: %s\n' "$*" >&2; }

get() { busctl --user get-property "$SB" "$SBPATH" "$SBIFACE" "$1" | awk '{print $2}'; }

slider="$(get Brightness)" || exit 1
slider_max="$(get MaxBrightness)" || exit 1
hw_max="$(cat "$BL/max_brightness")" || exit 1

# the backlight value the slider should produce, and how far off still counts as a match
expected=$(( slider * hw_max / slider_max ))
tolerance=$(( hw_max * TOLERANCE_PCT / 100 ))

# dip toward the middle so the value always stays inside the slider's range
if [ "$slider" -gt "$DIP" ]; then dip=$(( slider - DIP )); else dip=$(( slider + DIP )); fi

for attempt in 1 2 3; do
    busctl --user call "$SB" "$SBPATH" "$SBIFACE" SetBrightness iu "$dip" 0 >/dev/null 2>&1
    sleep "$SETTLE"
    busctl --user call "$SB" "$SBPATH" "$SBIFACE" SetBrightness iu "$slider" 0 >/dev/null 2>&1
    sleep "$SETTLE"
    requested="$(cat "$BL/brightness")"
    diff=$(( requested > expected ? requested - expected : expected - requested ))
    if [ "$diff" -le "$tolerance" ]; then
        log "applied: slider $slider -> backlight $requested (expected about $expected), attempt $attempt"
        exit 0
    fi
    log "attempt $attempt: backlight is $requested, expected about $expected; retrying"
done

log "gave up: the backlight never followed the slider"
exit 1
