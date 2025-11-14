#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

apt-get update
apt-get install -y ffmpeg libcamera-apps unzip wget tar

if ! command -v systemctl >/dev/null 2>&1; then
  echo "Error: systemd is required for service management on Raspberry Pi OS." >&2
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

CONFIG_SRC="$SCRIPT_DIR/../config/mediamtx.yml"
START_SCRIPT_SRC="$SCRIPT_DIR/start_stream.sh"
STREAM_SERVICE_SRC="$SCRIPT_DIR/../systemd/rpicam-stream.service"
MEDIA_SERVICE_SRC="$SCRIPT_DIR/../systemd/mediamtx.service"

if [[ ! -f "$CONFIG_SRC" || ! -f "$START_SCRIPT_SRC" || ! -f "$STREAM_SERVICE_SRC" || ! -f "$MEDIA_SERVICE_SRC" ]]; then
  echo "Error: repository files not found. Run this script from within the cloned FW-IP-Cam repo." >&2
  exit 1
fi

MEDIAMTX_VERSION="latest"
ARCH=$(uname -m)
case "$ARCH" in
  armv7l|armv6l)
    MEDIAMTX_ARCH="armv7"
    ;;
  aarch64)
    MEDIAMTX_ARCH="arm64"
    ;;
  *)
    echo "Unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

# Create dedicated service account with access to camera hardware
if ! id -u mediamtx >/dev/null 2>&1; then
  useradd --system --user-group --home /var/lib/mediamtx --shell /usr/sbin/nologin mediamtx
fi

if getent group video >/dev/null 2>&1; then
  usermod -a -G video mediamtx
fi

if getent group render >/dev/null 2>&1; then
  usermod -a -G render mediamtx
fi

install -d -o mediamtx -g mediamtx /var/lib/mediamtx
install -d -o mediamtx -g mediamtx /var/log/mediamtx
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

URL="https://github.com/bluenviron/mediamtx/releases/${MEDIAMTX_VERSION}/download/mediamtx_linux_${MEDIAMTX_ARCH}.tar.gz"
FILE="$TMPDIR/mediamtx.tar.gz"

wget -qO "$FILE" "$URL"
tar -xzf "$FILE" -C "$TMPDIR"
install -m 755 "$TMPDIR"/mediamtx /usr/local/bin/mediamtx
install -o mediamtx -g mediamtx -m 640 "$CONFIG_SRC" /etc/mediamtx.yml

install -o mediamtx -g mediamtx -m 750 "$START_SCRIPT_SRC" /usr/local/bin/start_pi_stream
install -o root -g root -m 644 "$STREAM_SERVICE_SRC" /etc/systemd/system/rpicam-stream.service
install -o root -g root -m 644 "$MEDIA_SERVICE_SRC" /etc/systemd/system/mediamtx.service

systemctl daemon-reload
systemctl enable --now mediamtx.service
systemctl enable --now rpicam-stream.service

echo "Installation complete. Streaming services are now running."
echo "Check their status with:"
echo "  systemctl status mediamtx.service"
echo "  systemctl status rpicam-stream.service"
echo "If either unit is reported as 'not found', re-run this installer from the FW-IP-Cam repository."
