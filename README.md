# Hikvision Viewer

![Hikvision Viewer icon](Assets/AppIcon.png)

An independent, native Apple Silicon Mac app for viewing Hikvision recorder cameras and playing recordings. It connects directly over your LAN or VPN.

## Install

1. Install [VLC for Mac](https://www.videolan.org/vlc/) in `/Applications/VLC.app` for video playback.
2. Download the Mac app from [Releases](https://github.com/Delitants/Hikvision-Viewer/releases), unzip it, and move **Hikvision Viewer.app** to Applications.
3. Open the app. It imports recorder addresses, channels, and saved camera names from an existing iVMS-4200 installation when available. Enter each recorder's username and password when prompted. Passwords are stored in macOS Keychain.

This preview may ask for recorder passwords again after an update.

This preview is not Apple notarized. If macOS blocks its first launch, follow [Apple's Open Anyway instructions](https://support.apple.com/en-us/102445) after checking that you downloaded it from this repository.

Choose a camera for live view. **Four cameras** uses substreams to reduce bandwidth. For playback, choose a camera, open **Recordings**, select one day or a range of up to seven days in the calendar, and click **Search**. The timeline shows available footage. Click a time to play, drag to move through the recording, or use the zoom buttons and mouse wheel. You can also open a local video file.

Use **Devices** to add an NVR or individual camera by address, edit its channels, or search the LAN for ONVIF devices. After connecting, **Camera Names** reads channel names from a compatible device. Playback reconnects after interruptions and can switch to a lower-bandwidth recorded substream when the recorder provides one.

The app uses RTSP for video and Hikvision ISAPI for recording search. It does not include Hik-Connect cloud access or the other iVMS modules. It leaves iVMS-4200 unchanged.

Hikvision Viewer is an independent project and is not affiliated with Hikvision.
