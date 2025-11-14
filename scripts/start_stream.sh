#!/usr/bin/env bash
set -euo pipefail

WIDTH=${WIDTH:-1920}
HEIGHT=${HEIGHT:-1080}
FRAMERATE=${FRAMERATE:-30}
BITRATE=${BITRATE:-8000000}

# Prefer the modern rpicam stack but gracefully fall back to libcamera on
# older Raspberry Pi OS releases where the new commands are unavailable.
if [[ -z "${CAMERA_BIN:-}" ]]; then
  if command -v rpicam-vid >/dev/null 2>&1; then
    CAMERA_BIN="rpicam-vid"
  elif command -v libcamera-vid >/dev/null 2>&1; then
    CAMERA_BIN="libcamera-vid"
  else
    CAMERA_BIN="rpicam-vid"
  fi
fi
FFMPEG_BIN=${FFMPEG_BIN:-ffmpeg}
RTSP_URL=${RTSP_URL:-rtsp://127.0.0.1:8554/camera}
TEST_MODE=false

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  -w <width>        Video width in pixels (default: ${WIDTH})
  -h <height>       Video height in pixels (default: ${HEIGHT})
  -f <framerate>    Frames per second (default: ${FRAMERATE})
  -b <bitrate>      Bitrate in bits per second (default: ${BITRATE})
  -r <rtsp-url>     RTSP publish URL (default: ${RTSP_URL})
  -t                Test mode; stream directly without retry loop.
  -?                Show this help message.
USAGE
}

while getopts "w:h:f:b:r:t?" opt; do
  case "$opt" in
    w) WIDTH=$OPTARG ;;
    h) HEIGHT=$OPTARG ;;
    f) FRAMERATE=$OPTARG ;;
    b) BITRATE=$OPTARG ;;
    r) RTSP_URL=$OPTARG ;;
    t) TEST_MODE=true ;;
    ?) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done

if ! command -v "$CAMERA_BIN" >/dev/null 2>&1; then
  echo "Error: $CAMERA_BIN not found. Install the Raspberry Pi camera stack." >&2
  exit 1
fi

if ! command -v "$FFMPEG_BIN" >/dev/null 2>&1; then
  echo "Error: $FFMPEG_BIN not found. Install ffmpeg (sudo apt install ffmpeg)." >&2
  exit 1
fi

run_pipeline() {
  echo "Starting camera pipeline: ${WIDTH}x${HEIGHT}@${FRAMERATE} -> ${RTSP_URL}" >&2
  "$CAMERA_BIN" \
    --inline \
    --width "$WIDTH" \
    --height "$HEIGHT" \
    --framerate "$FRAMERATE" \
    --codec h264 \
    --bitrate "$BITRATE" \
    --timeout 0 \
    --profile high \
    --level 4.2 \
    --denoise cdn_off \
    --sharpness 1.0 \
    --nopreview \
    -o - \
    | "$FFMPEG_BIN" -hide_banner -loglevel warning \
        -re -f h264 -i - \
        -c copy -f rtsp "$RTSP_URL"
}

if [[ "$TEST_MODE" == true ]]; then
  run_pipeline
else
  while true; do
    if ! run_pipeline; then
      echo "Pipeline exited unexpectedly; restarting in 2 seconds..." >&2
      sleep 2
    else
      break
    fi
  done
fi
