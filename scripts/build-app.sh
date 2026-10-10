#!/bin/zsh
set -eu
cd "${0:A:h:h}"
CONFIGURATION="${1:-release}"
swift build -c "$CONFIGURATION" --product GitDesk
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP_DIR="$PWD/dist/GitDesk.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/GitDesk" "$APP_DIR/Contents/MacOS/GitDesk"
ICON_DIR="$PWD/.build/GitDesk.iconset"
swift scripts/render-icon.swift "$ICON_DIR"
iconutil -c icns "$ICON_DIR" -o "$APP_DIR/Contents/Resources/GitDesk.icns"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>GitDesk</string>
<key>CFBundleIdentifier</key><string>dev.gitdesk.app</string>
<key>CFBundleName</key><string>GitDesk</string>
<key>CFBundleDisplayName</key><string>GitDesk</string>
<key>CFBundleIconFile</key><string>GitDesk</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>Git Repository</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSItemContentTypes</key><array><string>public.folder</string></array></dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP_DIR"
print "Built $APP_DIR"
