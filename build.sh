#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export MACOSX_DEPLOYMENT_TARGET=13.0
if ! command -v rtk >/dev/null; then
  rtk() { if [[ "${1:-}" == proxy ]]; then shift; fi; command "$@"; }
fi
rtk cargo test --manifest-path core/Cargo.toml
rtk cargo build --release --manifest-path core/Cargo.toml
APP="${DISPLAY_HARBOR_APP_OUTPUT:-dist/Display Harbor.app}"
if rtk proxy pgrep -f "^$PWD/$APP/Contents/MacOS/DisplayHarbor$" >/dev/null; then
  echo "실행 중인 Display Harbor를 종료한 뒤 빌드하세요. 실행 파일 덮어쓰기를 방지했습니다."
  exit 1
fi
STAGE="dist/.build/Display Harbor.app"
rtk mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
rtk swiftc -parse-as-library -swift-version 5 -import-objc-header native/Core.h native/WindowDiscovery.swift native/WindowMover.swift native/WindowDiscoveryTests.swift \
  core/target/release/libdisplay_harbor_core.a -framework AppKit -framework ApplicationServices -o dist/.build/discovery-tests
rtk proxy dist/.build/discovery-tests
rtk swift native/MakeIcon.swift dist/.build/AppIcon.iconset
rtk iconutil -c icns dist/.build/AppIcon.iconset -o "$STAGE/Contents/Resources/AppIcon.icns"
rtk swiftc -O -parse-as-library -swift-version 5 -target "$(rtk proxy uname -m)-apple-macos13.0" -import-objc-header native/Core.h native/WindowDiscovery.swift native/WindowMover.swift native/WindowPreviews.swift native/App.swift \
  core/target/release/libdisplay_harbor_core.a \
  -framework SwiftUI -framework AppKit -framework ApplicationServices -framework ScreenCaptureKit \
  -o "$STAGE/Contents/MacOS/DisplayHarbor"
rtk strip -S -x "$STAGE/Contents/MacOS/DisplayHarbor"
rtk python3 scripts/check_binary_privacy.py "$STAGE/Contents/MacOS/DisplayHarbor"
rtk cp native/Info.plist "$STAGE/Contents/Info.plist"
rtk mkdir -p "$STAGE/Contents/Resources/third_party"
rtk cp -R third_party/. "$STAGE/Contents/Resources/third_party/"
# A Developer ID or Apple Development identity can be supplied for stable TCC
# identity across builds. Ad hoc fallback needs re-registration after updates.
rtk codesign --force --sign "${DISPLAY_HARBOR_SIGNING_IDENTITY:--}" "$STAGE"
rtk codesign --verify --strict "$STAGE"
if test -d "$APP"; then
  rtk mkdir -p dist/.previous
  rtk mv "$APP" "dist/.previous/Display Harbor-$(rtk proxy date +%s).app"
fi
rtk mkdir -p "$(rtk proxy dirname "$APP")"
rtk mv "$STAGE" "$APP"
rtk codesign --verify --strict "$APP"
echo "완료: $APP"
