#!/usr/bin/env bash
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SOURCE=$(cd "$HERE/.." && pwd)
BUILD=${SOC_BUILD_DIR:-"$SOURCE/build"}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
args=(-DCMAKE_BUILD_TYPE=Release -DBUILD_SYNCHRONOUS_BRIDGE=ON)

if [[ -n ${CROSS:-} ]]; then
    args+=(-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64
        -DCMAKE_CXX_COMPILER="${CROSS}g++")
fi

if [[ -n ${RKNN_SDK:-} ]]; then
    RKNN_LIBRARY=${RKNN_LIBRARY:-$(find "$RKNN_SDK" -name librknnrt.so -print -quit)}
    RKNN_INCLUDE_DIR=${RKNN_INCLUDE_DIR:-$(find "$RKNN_SDK" -name rknn_api.h -printf '%h\n' -quit)}
    [[ -n "$RKNN_LIBRARY" && -n "$RKNN_INCLUDE_DIR" ]] || {
        echo 'RKNN_SDK must contain librknnrt.so and rknn_api.h.' >&2
        exit 2
    }
    args+=(-DBUILD_RKNN_WORKER=ON -DRKNN_LIBRARY="$RKNN_LIBRARY"
        -DRKNN_INCLUDE_DIR="$RKNN_INCLUDE_DIR")
    [[ -z ${OpenCV_DIR:-} ]] || args+=(-DOpenCV_DIR="$OpenCV_DIR")
else
    args+=(-DBUILD_RKNN_WORKER=OFF)
fi

cmake -S "$SOURCE" -B "$BUILD" "${args[@]}"
cmake --build "$BUILD" --parallel "$JOBS"
echo "Built binaries: $BUILD/bin"
