# FW-IP-Cam

Remote IP camera toolkit for running a Raspberry Pi 4B with PoE and a camera module as an always-on webcam that can be consumed from Windows machines.

## Repository Contents

- `docs/plan.md` – feasibility analysis and implementation roadmap.
- `scripts/install_pi.sh` – automated installer for Raspberry Pi OS (run with `sudo`).
- `scripts/start_stream.sh` – helper to start the capture/stream pipeline manually or via systemd.
- `config/mediamtx.yml` – baseline configuration for the Mediamtx RTSP server.
- `systemd/*.service` – systemd units for Mediamtx and the streaming pipeline.

## Raspberry Pi Installation

1. **Flash OS & confirm camera support**
   - Install Raspberry Pi OS (64-bit recommended) and apply all updates.
   - On current Raspberry Pi OS releases the libcamera stack is enabled automatically. If you are using an older image that still
     exposes `Legacy Camera` inside `sudo raspi-config` (`Interface Options` → `Legacy Camera`), enable it and reboot. If no camera
     option appears you can proceed—the modern camera stack is already active.
2. **Clone the repository**
   ```bash
   git clone https://github.com/<your-account>/FW-IP-Cam.git
   cd FW-IP-Cam
   ```
3. **Run the installer**
   ```bash
   sudo ./scripts/install_pi.sh
   ```
   This script will:
  - Install `ffmpeg`, the Raspberry Pi camera stack, helper utilities (`curl`, `wget`, `python3`), and Mediamtx.
   - Create a `mediamtx` service account with access to the camera hardware and apply required permissions.
   - Install the streaming helper and systemd unit files.
   - Enable and start the Mediamtx and camera streaming services so they launch automatically on boot and restart if interrupted.
4. **Verify streaming services**
   The installer enables and starts both services automatically. Confirm they are healthy with:
   ```bash
   sudo systemctl status mediamtx.service
   sudo systemctl status rpicam-stream.service
   ```
   The RTSP stream will be available at `rtsp://<pi-ip-address>:8554/camera`.

### Manual Testing on the Pi

To validate the pipeline without systemd (useful for troubleshooting), stop the services and run:
```bash
sudo systemctl stop rpicam-stream.service
./scripts/start_stream.sh -t
```
Press `Ctrl+C` to terminate the test stream.

## Windows Consumption

1. **Verify the stream** using VLC or ffplay:
   - Open VLC → `Media` → `Open Network Stream...` → enter `rtsp://<pi-ip-address>:8554/camera`.
   - Confirm the video plays smoothly.
2. **Expose as a webcam** for software that only recognises local cameras:
   - Install [OBS Studio](https://obsproject.com/download) and enable the built-in *Virtual Camera* (Tools → Start Virtual Camera). Add a new *Media Source* pointing to the RTSP URL.
   - Alternatively, install the [IP Camera Adapter](https://ip-webcam.appspot.com/) driver and configure it with the RTSP URL, enabling MJPEG transcoding via `ffmpeg` if required.
3. **Configure your Windows application** to use the OBS Virtual Camera or IP Camera Adapter as the video input.

## Maintenance & Customisation

- **Change resolution/bitrate**: Edit the `Environment=` lines in `systemd/rpicam-stream.service` and reload with `sudo systemctl daemon-reload` followed by `sudo systemctl restart rpicam-stream.service`.
- **Adjust Mediamtx config**: Update `/etc/mediamtx.yml` and restart `mediamtx.service`.
- **Software updates**: Pull repository updates and re-run `sudo ./scripts/install_pi.sh` to reinstall scripts and units.
- **Service missing errors**: If `systemctl` reports `Unit *.service not found`, re-run the installer or manually copy the unit files
  with `sudo cp systemd/*.service /etc/systemd/system/` followed by `sudo systemctl daemon-reload`.

## Troubleshooting

- Confirm the camera works locally with `libcamera-hello` or `rpicam-still`.
- Check service status logs:
  ```bash
  sudo journalctl -u mediamtx.service
  sudo journalctl -u rpicam-stream.service
  ```
- Ensure the Windows PC can reach the Pi's IP address over the network and that firewalls allow TCP port 8554.

