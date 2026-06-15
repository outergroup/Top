#!/bin/bash

set -euo pipefail
export COPYFILE_DISABLE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-${REPO_ROOT}/build/frontend}"
MACOS_BUILD_ROOT="${MACOS_BUILD_ROOT:-${REPO_ROOT}/build/macos}"
PACKAGE_ROOT="${PACKAGE_ROOT:-${REPO_ROOT}/build/linux-package}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${REPO_ROOT}/build/release}"
CONFIGURATION="${CONFIGURATION:-Release}"

require_file() {
    if [[ ! -f "$1" ]]; then
        echo "error: missing $1" >&2
        exit 1
    fi
}

require_file "${PACKAGE_ROOT}/RemoteLinuxBinaries/aarch64/TopBackend"
require_file "${PACKAGE_ROOT}/RemoteLinuxBinaries/x86_64/TopBackend"
require_file "${REPO_ROOT}/app-icon.png"

mkdir -p "${OUTPUT_ROOT}" "${PACKAGE_ROOT}/bundles"

echo "==> Building TopBackend for macOS"
/usr/bin/xcodebuild \
    -project "${REPO_ROOT}/Top.xcodeproj" \
    -scheme TopBackend \
    -configuration "${CONFIGURATION}" \
    SYMROOT="${MACOS_BUILD_ROOT}" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    build

require_file "${MACOS_BUILD_ROOT}/${CONFIGURATION}/TopBackend"

echo "==> Building Top frontend"
/usr/bin/xcodebuild \
    -project "${REPO_ROOT}/Top.xcodeproj" \
    -scheme Top \
    -configuration "${CONFIGURATION}" \
    SYMROOT="${BUILD_ROOT}" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

echo "==> Archiving TopContent bundles"
"${REPO_ROOT}/Scripts/archive_top_bundle.sh" \
    "${BUILD_ROOT}/${CONFIGURATION}/Top.bundle" \
    "${PACKAGE_ROOT}/bundles" \
    TopContent.bundle

STAGING_ROOT="$(mktemp -d)"
trap 'rm -rf "${STAGING_ROOT}"' EXIT

APP_ROOT="${STAGING_ROOT}/Top"
MACOS_APP_ROOT="${APP_ROOT}/Top.app"
mkdir -p \
    "${MACOS_APP_ROOT}/Contents/MacOS" \
    "${MACOS_APP_ROOT}/Contents/Resources/bundles" \
    "${APP_ROOT}/RemoteLinuxBinaries/aarch64" \
    "${APP_ROOT}/RemoteLinuxBinaries/x86_64" \
    "${APP_ROOT}/bundles"

install -m 0755 "${MACOS_BUILD_ROOT}/${CONFIGURATION}/TopBackend" "${MACOS_APP_ROOT}/Contents/MacOS/TopBackend"
install -m 0755 "${PACKAGE_ROOT}/RemoteLinuxBinaries/aarch64/TopBackend" "${APP_ROOT}/RemoteLinuxBinaries/aarch64/TopBackend"
install -m 0755 "${PACKAGE_ROOT}/RemoteLinuxBinaries/x86_64/TopBackend" "${APP_ROOT}/RemoteLinuxBinaries/x86_64/TopBackend"
install -m 0644 "${PACKAGE_ROOT}/bundles/TopContent.bundle.macos-arm.aar" "${APP_ROOT}/bundles/TopContent.bundle.macos-arm.aar"
install -m 0644 "${PACKAGE_ROOT}/bundles/TopContent.bundle.macos-x86.aar" "${APP_ROOT}/bundles/TopContent.bundle.macos-x86.aar"
install -m 0644 "${REPO_ROOT}/app-icon.png" "${APP_ROOT}/app-icon.png"
install -m 0644 "${PACKAGE_ROOT}/bundles/TopContent.bundle.macos-arm.aar" "${MACOS_APP_ROOT}/Contents/Resources/bundles/TopContent.bundle.macos-arm.aar"
install -m 0644 "${PACKAGE_ROOT}/bundles/TopContent.bundle.macos-x86.aar" "${MACOS_APP_ROOT}/Contents/Resources/bundles/TopContent.bundle.macos-x86.aar"
install -m 0644 "${REPO_ROOT}/app-icon.png" "${MACOS_APP_ROOT}/Contents/Resources/app-icon.png"
cat > "${MACOS_APP_ROOT}/Contents/Info.plist" <<'__TOP_INFO_PLIST__'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>TopBackend</string>
    <key>CFBundleIdentifier</key>
    <string>org.outershell.Top</string>
    <key>CFBundleName</key>
    <string>Top</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSBackgroundOnly</key>
    <true/>
</dict>
</plist>
__TOP_INFO_PLIST__

if command -v /usr/bin/codesign >/dev/null 2>&1; then
    /usr/bin/codesign --force --sign - --timestamp=none "${MACOS_APP_ROOT}" >/dev/null
fi

tar --format ustar --no-xattrs -C "${STAGING_ROOT}" -czf "${OUTPUT_ROOT}/Top.tar.gz" Top
echo "Packaged ${OUTPUT_ROOT}/Top.tar.gz"
