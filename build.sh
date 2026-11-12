#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
vlc_root="/Applications/VLC.app/Contents/MacOS"
app_dir="$project_dir/build/Hikvision Viewer.app"
rm -rf "$app_dir"
mkdir -p "$project_dir/.cache/clang" "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Assets/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"

CLANG_MODULE_CACHE_PATH="$project_dir/.cache/clang" xcrun swiftc \
  -disable-sandbox -O -target arm64-apple-macos13.0 \
  -sdk "$(xcrun --show-sdk-path)" \
  -import-objc-header "$project_dir/Sources/CameraApp/VLC-Bridging.h" \
  -I "$vlc_root/include" -L "$vlc_root/lib" \
  -Xlinker -rpath -Xlinker "$vlc_root/lib" \
  -lsqlite3 -lvlc \
  "$project_dir"/Sources/CameraCore/*.swift "$project_dir"/Sources/CameraApp/*.swift \
  -o "$app_dir/Contents/MacOS/HikvisionViewer"

codesign --force --sign - --timestamp=none "$app_dir"
file "$app_dir/Contents/MacOS/HikvisionViewer"
codesign --verify --strict "$app_dir"
