#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

log() {
  echo "[install_pi] $*"
}

warn() {
  echo "[install_pi][warn] $*" >&2
}

die() {
  echo "[install_pi][error] $*" >&2
  exit 1
}

log "Updating apt package index"
apt-get update
log "Installing camera and streaming dependencies"
apt-get install -y ffmpeg libcamera-apps unzip wget tar

if ! command -v systemctl >/dev/null 2>&1; then
  die "systemd is required for service management on Raspberry Pi OS."
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

CONFIG_SRC="$SCRIPT_DIR/../config/mediamtx.yml"
START_SCRIPT_SRC="$SCRIPT_DIR/start_stream.sh"
STREAM_SERVICE_SRC="$SCRIPT_DIR/../systemd/rpicam-stream.service"
MEDIA_SERVICE_SRC="$SCRIPT_DIR/../systemd/mediamtx.service"

if [[ ! -f "$CONFIG_SRC" || ! -f "$START_SCRIPT_SRC" || ! -f "$STREAM_SERVICE_SRC" || ! -f "$MEDIA_SERVICE_SRC" ]]; then
  die "Repository files not found. Run this script from within the cloned FW-IP-Cam repo."
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
    die "Unsupported architecture: $ARCH"
    ;;
esac

# Create dedicated service account with access to camera hardware
if ! id -u mediamtx >/dev/null 2>&1; then
  log "Creating mediamtx service account"
  useradd --system --user-group --home /var/lib/mediamtx --shell /usr/sbin/nologin mediamtx
fi

if getent group video >/dev/null 2>&1; then
  log "Granting mediamtx access to video group"
  usermod -a -G video mediamtx
fi

if getent group render >/dev/null 2>&1; then
  log "Granting mediamtx access to render group"
  usermod -a -G render mediamtx
fi

install -d -o mediamtx -g mediamtx /var/lib/mediamtx
install -d -o mediamtx -g mediamtx /var/log/mediamtx

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

URL="https://github.com/bluenviron/mediamtx/releases/${MEDIAMTX_VERSION}/download/mediamtx_linux_${MEDIAMTX_ARCH}.tar.gz"
FILE="$TMPDIR/mediamtx.tar.gz"

log "Downloading Mediamtx from $URL"
wget -qO "$FILE" "$URL" || die "Unable to download Mediamtx archive"
log "Extracting Mediamtx archive"
tar -xzf "$FILE" -C "$TMPDIR"
install -m 755 "$TMPDIR"/mediamtx /usr/local/bin/mediamtx
install -o mediamtx -g mediamtx -m 640 "$CONFIG_SRC" /etc/mediamtx.yml

log "Installing streaming helper and systemd units"
install -o mediamtx -g mediamtx -m 750 "$START_SCRIPT_SRC" /usr/local/bin/start_pi_stream
install -o root -g root -m 644 "$STREAM_SERVICE_SRC" /etc/systemd/system/rpicam-stream.service
install -o root -g root -m 644 "$MEDIA_SERVICE_SRC" /etc/systemd/system/mediamtx.service

for unit in mediamtx.service rpicam-stream.service; do
  if [[ ! -f "/etc/systemd/system/${unit}" ]]; then
    die "Expected /etc/systemd/system/${unit} to exist after installation"
  fi
done

log "Reloading systemd unit cache"
systemctl daemon-reload

log "Enabling and starting Mediamtx"
systemctl enable --now mediamtx.service
log "Enabling and starting camera streaming service"
systemctl enable --now rpicam-stream.service

for unit in mediamtx.service rpicam-stream.service; do
  if ! systemctl show -p FragmentPath --value "$unit" >/dev/null 2>&1; then
    die "systemd does not recognize ${unit}. Confirm the unit file exists in /etc/systemd/system and rerun the installer."
  fi
  if ! systemctl is-enabled "$unit" >/dev/null 2>&1; then
    die "${unit} is not enabled. Check systemctl output above and rerun the installer."
  fi
  if ! systemctl is-active "$unit" >/dev/null 2>&1; then
    warn "${unit} is installed but not running. Review 'sudo systemctl status ${unit}' for diagnostics."
  fi
done

echo "Installation complete. Streaming services are now running."
echo "Check their status with:"
echo "  systemctl status mediamtx.service"
echo "  systemctl status rpicam-stream.service"
echo "If either unit is reported as 'not found', re-run this installer from the FW-IP-Cam repository."
