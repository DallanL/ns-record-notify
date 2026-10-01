#!/usr/bin/env bash
# Install and validate the announcement prompt.
#
# Two things silently break a prompt, and neither shows up as a failed call --
# the call sounds completely normal and only the announcement is missing:
#
#   1. Wrong container format. "8 kHz 8-bit mono mu-law" describes the AUDIO
#      correctly, but Asterisk's format_wav reads 16-bit signed linear PCM only.
#      A mu-law-encoded .wav cannot be opened at all, and Asterisk quietly falls
#      back to whatever other extension it finds -- typically a stale prompt.
#   2. Too quiet. A prompt whispered under a live conversation is inaudible even
#      though every log line says it played.
#
#   ./scripts/prompt.sh install <your-recording>   convert, normalise, install
#   ./scripts/prompt.sh install --default         install the bundled "all calls are recorded" prompt
#   ./scripts/prompt.sh check                      validate what is installed
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# SOUNDS_DIR points the script somewhere else -- used by the integration tests so
# they never touch the prompt that is actually installed.
BASE=recording-notice
DIR="${SOUNDS_DIR:-$ROOT/asterisk/sounds}"
DEFAULT_SRC="$ROOT/asterisk/default-prompt/$BASE.wav"
CONTAINER="${CONTAINER:-ns-announce-asterisk}"

die() { echo "error: $*" >&2; exit 1; }
command -v sox >/dev/null || die "sox is required (apt install sox)"

install_prompt() {
    local src="$1"
    [ -f "$src" ] || die "no such file: $src"
    sox "$src" -n stat 2>/dev/null || die "sox cannot read '$src' -- is it audio?"

    # Re-installing from the preserved source is a normal thing to do (say, to
    # re-normalise), and cp onto itself is an error, so only copy when they differ.
    if [ "$(readlink -f "$src")" != "$(readlink -f "$DIR/$BASE.source.wav")" ]; then
        cp "$src" "$DIR/$BASE.source.wav"
    fi
    # 16-bit signed PCM: the only WAV encoding format_wav accepts.
    sox "$src" -r 8000 -c 1 -b 16 -e signed-integer "$DIR/$BASE.wav" norm -3
    # Raw headerless mu-law, matching the trunk codec so playback needs no
    # transcode. Both are installed so Asterisk can pick per call.
    sox "$DIR/$BASE.wav" -r 8000 -c 1 -b 8 -e mu-law -t raw "$DIR/$BASE.ulaw"
    echo "installed $BASE.wav and $BASE.ulaw (original kept as $BASE.source.wav)"
    echo
    check_prompt
}

check_prompt() {
    local fail=0

    for f in "$DIR/$BASE.wav" "$DIR/$BASE.ulaw"; do
        [ -f "$f" ] || { echo "MISSING  $(basename "$f")"; fail=1; continue; }
        printf '%-28s %s\n' "$(basename "$f")" "$(file -b "$f")"
    done

    if [ -f "$DIR/$BASE.wav" ]; then
        if file -b "$DIR/$BASE.wav" | grep -q "Microsoft PCM, 16 bit"; then
            echo "OK       .wav is 16-bit PCM"
        else
            echo "BROKEN   .wav is not 16-bit PCM -- Asterisk cannot open it"
            fail=1
        fi
    fi

    # Nothing to measure if the file is not there -- and sox on a missing file exits
    # non-zero, which under set -e would end the script here with no verdict at all.
    if [ -f "$DIR/$BASE.wav" ]; then
        # Measure the SPEECH, not the file: trailing silence drags whole-file RMS
        # down and makes a perfectly good prompt look too quiet.
        local peak rms stats
        stats=$(sox "$DIR/$BASE.wav" -n silence 1 0.1 0.5% -1 0.1 0.5% stat 2>&1 || true)
        peak=$(echo "$stats" | awk '/Maximum amplitude/ {print $3}')
        rms=$(echo "$stats" | awk '/RMS *amplitude/ {print $3}')
        # A prompt quiet enough that silence-stripping consumes the whole file
        # reports 0 and nan. Fall back to the unstripped stats so the numbers shown
        # are real -- the verdict is the same either way, but "-nan" reads like a
        # broken script rather than a broken prompt.
        if [ -z "$peak" ] || [ "$peak" = "0.000000" ] || [ "$rms" = "-nan" ]; then
            stats=$(sox "$DIR/$BASE.wav" -n stat 2>&1 || true)
            peak=$(echo "$stats" | awk '/Maximum amplitude/ {print $3}')
            rms=$(echo "$stats" | awk '/RMS *amplitude/ {print $3}')
        fi
        echo "speech peak $peak (want 0.50-0.90), speech RMS $rms (want 0.05-0.20)"
        awk -v p="$peak" -v r="$rms" 'BEGIN {
            if (p < 0.4)  { print "TOO QUIET  peak is low -- callers may not hear this"; exit 1 }
            if (p > 0.95) { print "TOO LOUD   peak is clipping"; exit 1 }
            if (r < 0.03) { print "TOO QUIET  speech RMS is low"; exit 1 }
            print "OK       level is in range"
        }' || fail=1
    fi

    # The authority on whether Asterisk can read it is Asterisk.
    if [ -n "${SOUNDS_DIR:-}" ]; then
        echo "note     SOUNDS_DIR is set, so $DIR is not what the container mounts; skipped the Asterisk-side check"
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
        for f in "$BASE.wav" "$BASE.ulaw"; do
            [ -f "$DIR/$f" ] || continue
            if docker exec "$CONTAINER" asterisk -rx \
                "file convert /var/lib/asterisk/sounds/custom/$f /tmp/promptcheck.slin" 2>&1 \
                | grep -q "^Converted"; then
                echo "OK       Asterisk opened $f"
            else
                echo "BROKEN   Asterisk could NOT open $f"
                fail=1
            fi
        done
    else
        echo "note     $CONTAINER is not running; skipped the Asterisk-side check"
    fi

    [ "$fail" -eq 0 ] && echo && echo "prompt looks good." || { echo; echo "prompt has problems (above)."; return 1; }
}

case "${1:-check}" in
    install)
        shift
        if [ "${1:-}" = "--default" ] && [ $# -eq 1 ]; then
            [ -f "$DEFAULT_SRC" ] || die "the bundled prompt is missing: $DEFAULT_SRC"
            install_prompt "$DEFAULT_SRC"
            echo
            echo "This is the stock \"all calls are recorded\" prompt. The wording that is right for"
            echo "your callers and jurisdiction is your decision -- replace it with your own with:"
            echo "    ./scripts/prompt.sh install <your-recording>"
        else
            [ $# -eq 1 ] || die "usage: $0 install <recording> | install --default"
            install_prompt "$1"
        fi ;;
    check)   check_prompt ;;
    *)       die "usage: $0 [check | install <recording> | install --default]" ;;
esac
