#!/bin/zsh
# Launches Mars Calendar with safe DEMO data — real calendars are never touched.
# Demo arguments only exist in Debug builds. Build each time so the launched
# app includes the current source; Xcode reuses unchanged build products.
APP="$HOME/Library/Developer/Xcode/DerivedData/MarsCalendar/Build/Products/Debug/MarsCalendar.app"
HERE="$(cd "$(dirname "$0")" && pwd)"
echo "Building the current Debug demo…"
xcodebuild -project "$HERE/MarsCalendar.xcodeproj" -scheme MarsCalendar \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/MarsCalendar" build || exit 1
open -n "$APP" --args -seedDemoData -demoWeather
