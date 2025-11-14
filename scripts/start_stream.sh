#!/usr/bin/env bash
set -euo pipefail

terminate_children() {
  if command -v pkill >/dev/null 2>&1; then
    pkill -P $$ 2>/dev/null || true
  else
    while read -r child; do
      [[ -n "$child" ]] || continue
      kill "$child" 2>/dev/null || true
    done < <(ps -o pid= --ppid $$ 2>/dev/null)
  fi
}
trap terminate_children EXIT

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

if [[ -z "${CAMERA_CHECK_BIN:-}" ]]; then
  if command -v rpicam-hello >/dev/null 2>&1; then
    CAMERA_CHECK_BIN="rpicam-hello"
  elif command -v libcamera-hello >/dev/null 2>&1; then
    CAMERA_CHECK_BIN="libcamera-hello"
  else
    CAMERA_CHECK_BIN=""
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

camera_available() {
  if [[ -z "$CAMERA_CHECK_BIN" ]]; then
    return 0
  fi

  local output
  if ! output=$("$CAMERA_CHECK_BIN" --list-cameras 2>&1); then
    echo "$CAMERA_CHECK_BIN --list-cameras failed: $output" >&2
    echo "Ensure the Raspberry Pi camera stack is installed and try again." >&2
    return 1
  fi

  if grep -Eqi "no cameras available|failed to acquire camera|device or resource busy|in use by another process" <<<"$output"; then
    echo "No cameras detected by $CAMERA_CHECK_BIN. Ensure the camera ribbon cable is seated and the interface is enabled." >&2
    return 1
  fi

  return 0
}

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
  if ! camera_available; then
    exit 1
  fi
  run_pipeline
else
  while true; do
    if ! camera_available; then
      echo "Retrying camera detection in 10 seconds..." >&2
      sleep 10
      continue
    fi

    if ! run_pipeline; then
      echo "Pipeline exited unexpectedly; restarting in 2 seconds..." >&2
      sleep 2
    else
      break
    fi
  done
fi
