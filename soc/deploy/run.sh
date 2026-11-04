#!/usr/bin/env bash
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SOURCE=$(cd "$HERE/.." && pwd)
BUILD=${SOC_BUILD_DIR:-"$SOURCE/build"}
BRIDGE=${ROI_BRIDGE:-"$BUILD/bin/soc_uart_bridge"}
WORKER=${ROI_WORKER:-"$BUILD/bin/bird_single_image"}
DEVICE=${ROI_DEVICE:-/dev/ttyFIQ0}
SCRATCH=${ROI_SCRATCH:-/tmp/birdguard_roi}
MMAP_UART=${MMAP_UART:-1}
: "${ROI_MODEL:?Set ROI_MODEL to the RKNN model file.}"

[[ -x "$BRIDGE" && -x "$WORKER" && -f "$ROI_MODEL" ]] || {
    echo 'Check ROI_BRIDGE, ROI_WORKER and ROI_MODEL.' >&2
    exit 2
}
mkdir -p "$SCRATCH"
args=(--device "$DEVICE" --baud 1500000 --worker "$WORKER"
    --model "$ROI_MODEL" --scratch "$SCRATCH" --worker-ms 5000
    --reply-delay-ms 0)

if [[ "$MMAP_UART" == 1 ]]; then
    [[ $(id -u) == 0 && -r /dev/mem && -w /dev/mem ]] || {
        echo 'The mmap UART transport requires root access to /dev/mem.' >&2
        exit 3
    }
    dmesg -n 1
    console=/sys/module/fiq_debugger/parameters/console_enable
    disable=/sys/module/fiq_debugger/parameters/disable
    [[ ! -w "$console" ]] || echo N > "$console"
    [[ ! -w "$disable" ]] || echo Y > "$disable"
    [[ ! -r "$disable" || $(cat "$disable") == Y ]] || exit 3
    args+=(--mmap-uart)
fi

[[ ${ROI_LENIENT_CRC:-1} == 0 ]] || args+=(--lenient-crc)
[[ ${ROI_RESULT_EXT:-0} == 0 ]] || args+=(--result-ext)
[[ -z ${ROI_CAPTURE_DIR:-} ]] || args+=(--capture-dir "$ROI_CAPTURE_DIR")
export BIRD_ENHANCE=${BIRD_ENHANCE:-0}
export BIRD_CONF_MIN=${BIRD_CONF_MIN:-0.30}
export REPLY_REPEAT=${REPLY_REPEAT:-3}

# Keep one owner for the UART transport.
exec flock -n /run/lock/birdguard-uart.lock "$BRIDGE" "${args[@]}"
