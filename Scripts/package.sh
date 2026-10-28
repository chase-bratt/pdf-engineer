#!/bin/bash
# Builds PDFEngineer.app.
#
# A .app is just a directory with a known layout, so SwiftPM builds the binary
# and this script assembles the bundle around it. That avoids maintaining an
# Xcode project for what amounts to a plist and a folder.
#
# Usage: ./Scripts/package.sh [--debug]
#
# Release is the default: a packaged .app is what gets handed to people, and a
# debug build carries `#if DEBUG` test hooks and assertions that must never
# ship. `--debug` builds a debug bundle for local development only.
# (`--release` is still accepted, and is the same as no flag.)
set -euo pipefail

cd "$(dirname "$0")/.."
source Scripts/env.sh

CONFIG="release"
case "${1:-}" in
  "" | --release) ;;
  --debug) CONFIG="debug" ;;
  *) echo "usage: $0 [--debug]" >&2; exit 64 ;;
esac

if [[ "$CONFIG" == "debug" ]]; then
  echo "warning: debug bundle — contains DEBUG-only hooks; for local development, never distribute" >&2
fi

APP_NAME="PDFEngineer"
BUNDLE_ID="com.pdfengineer.app"
VERSION="0.1.0"
BUILD="1"
OUT="build/${APP_NAME}.app"

echo "==> Building ($CONFIG)"
# Map the checkout path to "." so binaries don't embed the builder's home
# folder (C/C++ dependencies record source paths for assertions).
PREFIX_MAP=(
  -Xcc "-ffile-prefix-map=$PWD=." -Xcxx "-ffile-prefix-map=$PWD=."
  -Xswiftc -file-prefix-map -Xswiftc "$PWD=."
)
swift build -c "$CONFIG" "${PREFIX_MAP[@]}" --product "$APP_NAME"
swift build -c "$CONFIG" "${PREFIX_MAP[@]}" --product pdfeng-mcp
swift build -c "$CONFIG" "${PREFIX_MAP[@]}" --product pdfeng

BIN=".build/${CONFIG}/${APP_NAME}"
[[ -f "$BIN" ]] || { echo "error: no binary at $BIN" >&2; exit 1; }

echo "==> Assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/$APP_NAME"

# The MCP helper and CLI ship inside the bundle. Claude launches the helper
# over stdio, and the sandbox permits process-exec within the app's own bundle
# so this is the location that stays viable when the app is
# sandboxed later.
for helper in pdfeng-mcp pdfeng; do
  if [[ -f ".build/${CONFIG}/${helper}" ]]; then
    cp ".build/${CONFIG}/${helper}" "$OUT/Contents/MacOS/${helper}"
    echo "    bundled $helper"
  fi
done

cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"

# SwiftUI needs a real bundle with an identifier; running the bare binary does
# not start the app properly.
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>           <string>PDF Engineer</string>
    <key>CFBundleIdentifier</key>            <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>               <string>${BUILD}</string>
    <key>CFBundleShortVersionString</key>    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>            <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>LSMinimumSystemVersion</key>        <string>26.0</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <!-- Document-based, but without SwiftUI's DocumentGroup: the app owns the
         open/save lifecycle itself (see PDFEngineerApp.swift). -->
    <key>NSPrincipalClass</key>              <string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>      <string>PDF Document</string>
            <key>CFBundleTypeRole</key>      <string>Editor</string>
            <key>LSHandlerRank</key>         <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>com.adobe.pdf</string></array>
        </dict>
        <dict>
            <!-- HTML is converted to PDF on open: saving a webpage as HTML is
                 much faster than printing it to PDF. Rank Alternate so we never
                 displace the user's browser as the default handler. -->
            <key>CFBundleTypeName</key>      <string>HTML Document</string>
            <key>CFBundleTypeRole</key>      <string>Viewer</string>
            <key>LSHandlerRank</key>         <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.html</string>
                <string>public.xhtml</string>
            </array>
        </dict>
        <dict>
            <!-- Office documents, text and images convert to PDF on open.
                 Alternate rank: never displaces Word, TextEdit or Preview. -->
            <key>CFBundleTypeName</key>      <string>Convertible Document</string>
            <key>CFBundleTypeRole</key>      <string>Viewer</string>
            <key>LSHandlerRank</key>         <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>org.openxmlformats.wordprocessingml.document</string>
                <string>com.microsoft.word.doc</string>
                <string>public.rtf</string>
                <string>com.apple.rtfd</string>
                <string>org.oasis-open.opendocument.text</string>
                <string>public.plain-text</string>
                <string>net.daringfireball.markdown</string>
                <string>public.comma-separated-values-text</string>
                <string>public.png</string>
                <string>public.jpeg</string>
                <string>public.heic</string>
                <string>public.tiff</string>
                <string>com.compuserve.gif</string>
                <string>com.microsoft.bmp</string>
                <string>org.webmproject.webp</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "==> Signing"
# Sign with a Developer ID / Apple Development identity when one exists, else
# ad-hoc. Ad-hoc runs fine locally; it just cannot be distributed.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE '"(Developer ID Application|Apple Development)[^"]*"' \
  | head -1 | tr -d '"')

SIGN_ID="${IDENTITY:--}"
if [[ -n "$IDENTITY" ]]; then
  echo "    identity: $IDENTITY"
else
  echo "    no identity found; signing ad-hoc (local use only)"
fi

# Nested code signs first: codesign verifies inside-out, so signing the outer
# bundle before its helpers invalidates the result.
for helper in pdfeng-mcp pdfeng; do
  [[ -f "$OUT/Contents/MacOS/${helper}" ]] || continue
  codesign --force --options runtime --timestamp=none \
           --sign "$SIGN_ID" "$OUT/Contents/MacOS/${helper}"
done

codesign --force --options runtime --timestamp=none \
         --entitlements Resources/PDFEngineer.entitlements \
         --sign "$SIGN_ID" "$OUT"

codesign --verify --verbose=1 "$OUT" 2>&1 | tail -2

echo
echo "==> Built $OUT"
echo "    open $OUT"
