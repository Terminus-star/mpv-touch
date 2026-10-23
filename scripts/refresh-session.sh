#!/usr/bin/env bash
# refresh-session: a matched display refresh rate while something that wants it is running, your previous mode after.
#
# Why: 23.976 fps video does not divide into 180 Hz (7.5 refreshes per frame), so frames are held 7 and
# 8 refreshes alternately: steady judder. At 143.856 Hz it is exactly 6 refreshes per frame. Measured on
# this laptop (scratch/cadence-intervals.py): 4 % of frames on time at 180 Hz, 90 % at a fixed 143.77 Hz.
# KDE can only store a mode near that rate (143.87 Hz), see refresh-session.conf. Several programs can
# ask at once, so this keeps a list of "requesters": the mode is switched when the first one arrives and
# the previous mode comes back when the last one is gone. Same design as hdr-session.sh.
#
# Usage:
#   refresh-session.sh setup                 add the custom mode to KDE if it is not there yet (once)
#   refresh-session.sh acquire NAME [PID]    register a requester (PID defaults to the caller's parent)
#   refresh-session.sh release NAME [PID]    remove it
#   refresh-session.sh run NAME -- CMD...    switch, run CMD, release when it exits (even on Ctrl+C)
#   refresh-session.sh status                show the requesters and the display mode
#   refresh-session.sh watch                 loop: drop requests from programs that died, so a crash cannot
#                                            leave the display on the matched mode. Meant to run as a user service.
#
# Settings: scripts/refresh-session.conf (or the file named in REFRESH_SESSION_CONF).
# State lives in $XDG_RUNTIME_DIR/refresh-session (gone at logout; a requester file is NAME__PID).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${REFRESH_SESSION_CONF:-$HERE/refresh-session.conf}"

# defaults, overridden by the conf file
OUTPUT=eDP-1
TARGET_HZ=143.856
TOLERANCE_HZ=0.05
CUSTOM_MHZ=143950
CUSTOM_BLANKING=reduced
SETTLE_SECONDS=2
NOTIFY=1
POLL_SECONDS=2
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

RUNDIR="${XDG_RUNTIME_DIR:-/tmp}/refresh-session"
REQS="$RUNDIR/requests"
SAVED="$RUNDIR/saved"
mkdir -p "$REQS"

log() { printf 'refresh-session: %s\n' "$*" >&2; }

notify() {   # notify TITLE [BODY]
    [ "$NOTIFY" = 1 ] || return 0
    command -v notify-send >/dev/null 2>&1 || return 0
    notify-send -a "Refresh session" -e -t 5000 "$1" "${2:-}" >/dev/null 2>&1 || true
}

# the display settings with colour codes removed, cut down to the block of OUTPUT
read_state() {
    kscreen-doctor -o | sed 's/\x1b\[[0-9;]*m//g' \
        | awk -v n="$OUTPUT" '/^Output:/ { on = ($3 == n) } on'
}
# every mode as ID:WIDTHxHEIGHT@HZ, with * on the active one and ! on the preferred one
modes() { grep -o '[0-9]\+:[0-9]\+x[0-9]\+@[0-9.]\+[*!]*' <<<"$STATE"; }
current_mode() { modes | grep '\*' | head -n 1; }

# print the id of the mode with the active mode's size and the refresh closest to TARGET_HZ (within
# TOLERANCE_HZ), or nothing when there is none
find_target() {
    local size
    size="$(current_mode | sed -E 's/^[0-9]+:([0-9]+x[0-9]+)@.*/\1/')"
    modes | awk -F'[:@*!]' -v size="$size" -v t="$TARGET_HZ" -v tol="$TOLERANCE_HZ" '
        $2 == size { d = $3 - t; if (d < 0) d = -d
                     if (d <= tol && (best == "" || d < bd)) { best = $1; bd = d } }
        END { if (best != "") print best }'
}

# One lock around every change, so two programs asking at the same moment cannot interleave.
locked() { ( flock 9; "$@" ) 9>"$RUNDIR/lock"; }

count_requests() { find "$REQS" -type f | wc -l; }

# the file name of a requester; names are cleaned so they cannot contain the separator or a slash
req_file() { printf '%s/%s__%s' "$REQS" "${1//[^A-Za-z0-9._-]/_}" "$2"; }

do_acquire() {   # do_acquire NAME PID
    local name="$1" pid="$2" first=0 cur target
    do_reap
    [ "$(count_requests)" -eq 0 ] && first=1
    : > "$(req_file "$name" "$pid")"
    if [ "$first" -eq 0 ]; then
        log "$name joined; the display is already on the matched mode for another requester"
        return 0
    fi
    STATE="$(read_state)"
    cur="$(current_mode)"
    target="$(find_target)"
    if [ -z "$target" ]; then
        log "WARNING: no mode near ${TARGET_HZ} Hz on $OUTPUT (run: $0 setup); leaving the mode alone"
        printf 'PREV_MODE=\n' > "$SAVED"
        return 0
    fi
    printf 'PREV_MODE=%q\n' "${cur%%:*}" > "$SAVED"
    if [ "${cur%%:*}" = "$target" ]; then
        log "$name asked for ${TARGET_HZ} Hz: the display is already on it"
        return 0
    fi
    log "$name asked for ${TARGET_HZ} Hz: switching from mode ${cur%%:*} to mode $target"
    kscreen-doctor "output.$OUTPUT.mode.$target" >/dev/null 2>&1 \
        || log "WARNING: kscreen-doctor failed to switch the mode"
    notify "Refresh rate matched" "for $name"
    sleep "$SETTLE_SECONDS"
}

do_release() {   # do_release NAME PID
    local name="$1" pid="$2"
    rm -f "$(req_file "$name" "$pid")"
    if [ "$(count_requests)" -ne 0 ]; then
        log "$name released; the display stays on the matched mode for the others"
        return 0
    fi
    if [ ! -r "$SAVED" ]; then
        log "$name released; nothing saved to restore"
        return 0
    fi
    # shellcheck disable=SC1090
    . "$SAVED"
    if [ -n "$PREV_MODE" ]; then
        STATE="$(read_state)"
        if [ "$(current_mode | sed 's/:.*//')" = "$PREV_MODE" ]; then
            log "$name released; the display is already on the previous mode"
        else
            log "$name released; restoring mode $PREV_MODE"
            kscreen-doctor "output.$OUTPUT.mode.$PREV_MODE" >/dev/null 2>&1 \
                || log "WARNING: kscreen-doctor failed to restore the mode"
            notify "Refresh rate restored" "back to the previous mode"
        fi
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

cmd_setup() {
    STATE="$(read_state)"
    local target cur size id
    target="$(find_target)"
    if [ -n "$target" ]; then
        echo "already there: mode $target is within ${TOLERANCE_HZ} Hz of ${TARGET_HZ} Hz on $OUTPUT"
        return 0
    fi
    cur="$(current_mode)"
    size="$(sed -E 's/^[0-9]+:([0-9]+)x([0-9]+)@.*/\1.\2/' <<<"$cur")"
    id="$(kscreen-doctor -o | sed 's/\x1b\[[0-9;]*m//g' | awk -v n="$OUTPUT" '/^Output:/ && $3 == n { print $2 }')"
    [ -n "$id" ] || { log "cannot find the output id of $OUTPUT"; return 1; }
    echo "adding a custom mode ${size/./x} at $CUSTOM_MHZ mHz ($CUSTOM_BLANKING blanking) to $OUTPUT"
    kscreen-doctor "output.$id.addCustomMode.$size.$CUSTOM_MHZ.$CUSTOM_BLANKING"
    STATE="$(read_state)"
    target="$(find_target)"
    if [ -n "$target" ]; then
        echo "done: KDE stored it as mode $target"
    else
        log "WARNING: the mode was added but KDE stored it outside ${TOLERANCE_HZ} Hz of ${TARGET_HZ} Hz; adjust CUSTOM_MHZ"
        return 1
    fi
}

cmd_status() {
    STATE="$(read_state)"
    echo "display: active mode $(current_mode), matched mode id: $(find_target)"
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
    log "watching every ${POLL_SECONDS}s"
    while true; do
        locked do_reap
        sleep "$POLL_SECONDS"
    done
}

case "${1:-}" in
setup)
    cmd_setup
    ;;
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
    sed -n '2,22p' "$0" >&2
    exit 2
    ;;
esac
