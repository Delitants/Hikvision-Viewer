# Hikvision Viewer

![Hikvision Viewer icon](Assets/AppIcon.png)

An independent, native Apple Silicon Mac app for viewing Hikvision recorder cameras and playing recordings. It connects directly over your LAN or VPN.

## Install

1. Install [VLC for Mac](https://www.videolan.org/vlc/) in `/Applications/VLC.app` for video playback.
2. Download the Mac app from [Releases](https://github.com/Delitants/Hikvision-Viewer/releases), unzip it, and move **Hikvision Viewer.app** to Applications.
3. Open the app. It imports recorder addresses, channels, and saved camera names from an existing iVMS-4200 installation when available. Enter each recorder's username and password when prompted. Passwords are stored in macOS Keychain.

This preview may ask for recorder passwords again after an update.

This preview is not Apple notarized. If macOS blocks its first launch, follow [Apple's Open Anyway instructions](https://support.apple.com/en-us/102445) after checking that you downloaded it from this repository.

Choose a camera for live view. **Four cameras** uses substreams to reduce bandwidth. For playback, choose a camera, open **Recordings**, select a date, and click **Search**. You can also open a local video file.

The app uses RTSP for video and Hikvision ISAPI for recording search. It does not include Hik-Connect cloud access or the other iVMS modules. It leaves iVMS-4200 unchanged.

Hikvision Viewer is an independent project and is not affiliated with Hikvision.
