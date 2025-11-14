# Feasibility and Implementation Plan

## Feasibility Assessment
Using a Raspberry Pi 4B with a PoE HAT and an official camera module as an always-on network camera is entirely feasible. The Raspberry Pi OS ecosystem already provides camera capture utilities (`libcamera`/`rpicam`) and third-party components (e.g. Mediamtx, formerly `rtsp-simple-server`) that can expose an RTSP stream without authentication. Windows applications that expect a local webcam can consume the RTSP feed via bridge drivers such as OBS Studio's Virtual Camera or the "IP Camera Adapter" driver, allowing them to present the remote stream as a DirectShow device. No security or authentication will be enforced, satisfying the requirements.

## High-Level Architecture
1. **Capture** video from the Raspberry Pi camera using `rpicam-vid` (or `libcamera-vid` on older OS releases).
2. **Encode** the video as H.264 and pipe it to `ffmpeg`.
3. **Publish** the encoded stream to Mediamtx, an RTSP server running locally on the Pi.
4. **Consume** the RTSP stream (`rtsp://<pi-ip>:8554/camera`) from the Windows PC using the existing software or a virtual webcam bridge.

## Implementation Tasks
1. Provide shell scripts to install dependencies on the Raspberry Pi and configure Mediamtx plus systemd services.
2. Provide reusable scripts for starting/stopping the camera stream manually.
3. Provide a systemd service unit to run the stream automatically on boot.
4. Document installation steps for the Raspberry Pi and client-side consumption on Windows, including testing guidance.

## Testing Strategy
- On the Raspberry Pi, validate that the `rpicam-vid` pipeline can capture and stream by running `./scripts/start_stream.sh -t` (no systemd).
- From a Windows PC, use VLC or ffplay to confirm the RTSP stream is accessible.
- Install a virtual webcam bridge (OBS Studio Virtual Camera or IP Camera Adapter) to expose the RTSP stream as a standard webcam to the target application.

