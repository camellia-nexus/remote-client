#!/usr/bin/env bash
set -euo pipefail

(
	cd flutter
	dart run tool/generate_brand_assets.dart
)

asset_status="$(
	git status --porcelain --untracked-files=all -- \
		res/android-foreground.png \
		res/android-monochrome.png \
		res/camellia-mark.svg \
		res/icon.ico \
		res/icon.png \
		res/mac-icon.png \
		res/mac-tray-dark-x2.png \
		res/mac-tray-light-x2.png \
		res/scalable.svg \
		res/tray-icon.ico \
		res/tray-icon.png \
		res/32x32.png \
		res/64x64.png \
		res/128x128.png \
		res/128x128@2x.png \
		flutter/android/app/src/main/res \
		flutter/assets/brand-mark.png \
		flutter/assets/brand-mark-dark.png \
		flutter/assets/icon.svg \
		flutter/ios/Runner/Assets.xcassets/AppIcon.appiconset \
		flutter/macos/Runner/AppIcon.icns \
		flutter/plugins/desktop_multi_window/windows/resources/app_icon.ico \
		flutter/web/favicon.png \
		flutter/web/favicon.svg \
		flutter/web/icons \
		flutter/windows/runner/resources/app_icon.ico
)"
if [[ -n "$asset_status" ]]; then
	echo "Generated brand assets differ from the reviewed source:" >&2
	printf '%s\n' "$asset_status" >&2
	exit 1
fi

echo "Generated brand assets match the reviewed source."
