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
apt-get install -y ffmpeg libcamera-apps unzip wget curl tar python3

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

ARCH=$(uname -m)
case "$ARCH" in
  armv6l)
    MEDIAMTX_ARCH="armv6"
    ;;
  armv7l)
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

RELEASE_API="https://api.github.com/repos/bluenviron/mediamtx/releases/latest"
log "Resolving Mediamtx release metadata"
if ! RELEASE_JSON=$(curl -fsSL "$RELEASE_API"); then
  die "Unable to query latest Mediamtx release information"
fi

if ! MEDIAMTX_URL=$(MEDIAMTX_ARCH="$MEDIAMTX_ARCH" MEDIAMTX_RELEASE_JSON="$RELEASE_JSON" python3 <<'PY'
import json
import os
import sys

release_json = os.environ.get("MEDIAMTX_RELEASE_JSON")
arch = os.environ.get("MEDIAMTX_ARCH")

if not release_json:
    print("Missing release metadata", file=sys.stderr)
    sys.exit(1)

if not arch:
    print("Missing architecture information", file=sys.stderr)
    sys.exit(1)

try:
    release = json.loads(release_json)
except json.JSONDecodeError as exc:
    print(f"Failed to parse release metadata: {exc}", file=sys.stderr)
    sys.exit(1)

for asset in release.get("assets", []):
    name = asset.get("name", "")
    if name.endswith(f"linux_{arch}.tar.gz"):
        url = asset.get("browser_download_url")
        if url:
            sys.stdout.write(url)
            sys.exit(0)

print(f"No release asset found for architecture '{arch}'", file=sys.stderr)
sys.exit(1)
PY
); then
  die "Unable to determine Mediamtx download URL for architecture ${MEDIAMTX_ARCH}"
fi

FILE="$TMPDIR/mediamtx.tar.gz"

log "Downloading Mediamtx from $MEDIAMTX_URL"
wget -qO "$FILE" "$MEDIAMTX_URL" || die "Unable to download Mediamtx archive"
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

log "Enabling Mediamtx"
systemctl enable mediamtx.service
log "Enabling camera streaming service"
systemctl enable rpicam-stream.service

log "Restarting Mediamtx to apply configuration"
systemctl restart mediamtx.service
log "Restarting camera streaming service"
systemctl restart rpicam-stream.service

check_rtsp_listener() {
  local host="127.0.0.1"
  local port=8554
  local attempt=0
  local max_attempts=10

  while (( attempt < max_attempts )); do
    if python3 - "$host" "$port" <<'PY' >/dev/null 2>&1; then
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])

try:
    with socket.create_connection((host, port), timeout=2):
        pass
except OSError:
    sys.exit(1)
PY
      log "Confirmed RTSP listener on ${host}:${port}"
      return 0
    fi

    sleep 1
    ((attempt++))
  done

  warn "Unable to confirm RTSP listener on ${host}:${port}. Check mediamtx logs with 'sudo journalctl -u mediamtx.service'."
  return 1
}

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

check_rtsp_listener || true

echo "Installation complete. Streaming services are now running."
echo "Check their status with:"
echo "  systemctl status mediamtx.service"
echo "  systemctl status rpicam-stream.service"
echo "If either unit is reported as 'not found', re-run this installer from the FW-IP-Cam repository."
