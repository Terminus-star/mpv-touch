#!/usr/bin/env bash
# hdr-session: HDR mode on while something that wants HDR is running, your previous display state after.
#
# Why: this laptop's panel is best used in SDR mode day to day (the backlight follows the slider, so
# contrast is better), but KDE only presents real HDR while the output is in HDR mode. Programs that
# play HDR (mpv, a nested gamescope) therefore need HDR switched on for as long as they run. Several
# of them can run at once, so this keeps a list of "requesters": HDR goes on when the first one arrives
# and your previous state (HDR on or off, wide gamut, profile source) comes back when the last one is gone.
#
# Usage:
#   hdr-session.sh acquire NAME [PID]   register a requester (PID defaults to the caller's parent)
#   hdr-session.sh release NAME [PID]   remove it
#   hdr-session.sh run NAME -- CMD...   switch HDR on, run CMD, release when it exits (even on Ctrl+C)
#   hdr-session.sh status               show the requesters and the display state
#   hdr-session.sh watch                loop: drop requests from programs that died (so a crash cannot
#                                       leave HDR stuck on) and treat running programs matching
#                                       WATCH_PATTERNS as requesters. Meant to run as a user service.
#
# Steam launch option example (HDR on before gamescope starts, off after):
#   /home/termis/Projects/mpv-touch/scripts/hdr-session.sh run steam-game -- gamescope --hdr-enabled -- %command%
#
# Settings: scripts/hdr-session.conf (or the file named in HDR_SESSION_CONF).
# State lives in $XDG_RUNTIME_DIR/hdr-session (gone at logout; a requester file is NAME__PID).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${HDR_SESSION_CONF:-$HERE/hdr-session.conf}"

# defaults, overridden by the conf file
OUTPUT=eDP-1
HDR_WCG=enable
HDR_SOURCE=ICC
SETTLE_SECONDS=2
NOTIFY=1
POLL_SECONDS=2
WATCH_PATTERNS=()
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

RUNDIR="${XDG_RUNTIME_DIR:-/tmp}/hdr-session"
REQS="$RUNDIR/requests"
SAVED="$RUNDIR/saved"
mkdir -p "$REQS"

log() { printf 'hdr-session: %s\n' "$*" >&2; }

notify() {   # notify TITLE [BODY]
    [ "$NOTIFY" = 1 ] || return 0
    command -v notify-send >/dev/null 2>&1 || return 0
    notify-send -a "HDR session" -e -t 5000 "$1" "${2:-}" >/dev/null 2>&1 || true
}

# the display settings with colour codes removed; field LABEL picks one value out of STATE
read_state() { kscreen-doctor -o | sed 's/\x1b\[[0-9;]*m//g'; }
field() { awk -F': *' -v label="$1" '$1 ~ label { print $2; exit }' <<<"$STATE"; }

# One lock around every change, so two programs asking at the same moment cannot interleave.
locked() { ( flock 9; "$@" ) 9>"$RUNDIR/lock"; }

count_requests() { find "$REQS" -type f | wc -l; }

# the file name of a requester; names are cleaned so they cannot contain the separator or a slash
req_file() { printf '%s/%s__%s' "$REQS" "${1//[^A-Za-z0-9._-]/_}" "$2"; }

do_acquire() {   # do_acquire NAME PID
    local name="$1" pid="$2" first=0
    do_reap
    [ "$(count_requests)" -eq 0 ] && first=1
    : > "$(req_file "$name" "$pid")"
    if [ "$first" -eq 0 ]; then
        log "$name joined; HDR is already on for another requester"
        return 0
    fi
    # first requester: remember how things were, then switch HDR on
    STATE="$(read_state)"
    {
        printf 'PREV_HDR=%q\n' "$(field '^[[:space:]]*HDR$')"
        printf 'PREV_WCG=%q\n' "$(field 'Wide Color Gamut')"
        printf 'PREV_SOURCE=%q\n' "$(field 'HDR color profile source')"
        printf 'PREV_NITS=%q\n' "$(field 'SDR brightness' | sed 's/ nits//')"
    } > "$SAVED"
    log "$name asked for HDR: switching on (wide gamut $HDR_WCG, profile source $HDR_SOURCE)"
    kscreen-doctor "output.$OUTPUT.hdr.enable" "output.$OUTPUT.wcg.$HDR_WCG" \
        "output.$OUTPUT.hdrColorProfileSource.$HDR_SOURCE" >/dev/null 2>&1 \
        || log "WARNING: kscreen-doctor failed to switch HDR on"
    notify "HDR on" "for $name"
    sleep "$SETTLE_SECONDS"
}

do_release() {   # do_release NAME PID
    local name="$1" pid="$2" args=()
    rm -f "$(req_file "$name" "$pid")"
    if [ "$(count_requests)" -ne 0 ]; then
        log "$name released; HDR stays on for the others"
        return 0
    fi
    if [ ! -r "$SAVED" ]; then
        log "$name released; nothing saved to restore"
        return 0
    fi
    # shellcheck disable=SC1090
    . "$SAVED"
    # HDR-only settings first, in the same call as the on/off switch so they cannot be reset between
    case "$PREV_WCG" in
    enabled) args+=("output.$OUTPUT.wcg.enable") ;;
    disabled) args+=("output.$OUTPUT.wcg.disable") ;;
    esac
    [ -n "$PREV_SOURCE" ] && args+=("output.$OUTPUT.hdrColorProfileSource.$PREV_SOURCE")
    if [ "$PREV_HDR" = enabled ]; then
        args+=("output.$OUTPUT.hdr.enable")
        [ -n "$PREV_NITS" ] && args+=("output.$OUTPUT.sdr-brightness.$PREV_NITS")
    else
        args+=("output.$OUTPUT.hdr.disable")
    fi
    log "$name released; restoring the previous display state (HDR was $PREV_HDR)"
    kscreen-doctor "${args[@]}" >/dev/null 2>&1 || log "WARNING: kscreen-doctor failed to restore"
    if [ "$PREV_HDR" != enabled ]; then
        # KDE leaves the backlight at 100 % after HDR; make it follow the slider again (see slider-reapply.sh)
        sleep 1
        "$HERE/slider-reapply.sh" || log "WARNING: the backlight did not follow the slider"
        notify "HDR off" "back to SDR mode"
    fi
    rm -f "$SAVED"
}

# remove requests whose program is gone, going through do_release so the display is restored too
do_reap() {
    local f pid name
    for f in "$REQS"/*; do
        [ -e "$f" ] || continue
        pid="${f##*__}"
        name="${f##*/}"
        name="${name%__*}"
        if ! kill -0 "$pid" 2>/dev/null; then
            log "$name (pid $pid) is gone without releasing"
            do_release "$name" "$pid"
        fi
    done
}

cmd_status() {
    STATE="$(read_state)"
    echo "display: HDR $(field '^[[:space:]]*HDR$'), wide gamut $(field 'Wide Color Gamut')"
    local n=0 f
    for f in "$REQS"/*; do
        [ -e "$f" ] || continue
        echo "requester: ${f##*/}"
        n=$((n + 1))
    done
    [ "$n" -eq 0 ] && echo "requesters: none"
    [ -r "$SAVED" ] && { echo "saved state:"; sed 's/^/  /' "$SAVED"; }
    return 0
}

cmd_watch() {
    log "watching every ${POLL_SECONDS}s (patterns: ${#WATCH_PATTERNS[@]})"
    local pattern pid exe name
    while true; do
        locked do_reap
        for pattern in "${WATCH_PATTERNS[@]}"; do
            for pid in $(pgrep -f "$pattern"); do
                exe="$(readlink "/proc/$pid/exe" 2>/dev/null)"
                name="auto-$(basename "${exe:-process}")"
                [ -e "$(req_file "$name" "$pid")" ] || locked do_acquire "$name" "$pid"
            done
        done
        sleep "$POLL_SECONDS"
    done
}

case "${1:-}" in
acquire)
    [ $# -ge 2 ] || { log "usage: $0 acquire NAME [PID]"; exit 2; }
    locked do_acquire "$2" "${3:-$PPID}"
    ;;
release)
    [ $# -ge 2 ] || { log "usage: $0 release NAME [PID]"; exit 2; }
    locked do_release "$2" "${3:-$PPID}"
    ;;
run)
    [ $# -ge 4 ] && [ "$3" = "--" ] || { log "usage: $0 run NAME -- COMMAND [ARGS...]"; exit 2; }
    name="$2"
    shift 3
    # this wrapper's own pid is the requester, so it stays registered exactly as long as the command runs
    locked do_acquire "$name" "$$"
    trap 'locked do_release "$name" "$$"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    "$@"
    ;;
status)
    cmd_status
    ;;
watch)
    cmd_watch
    ;;
*)
    sed -n '2,23p' "$0" >&2
    exit 2
    ;;
esac
