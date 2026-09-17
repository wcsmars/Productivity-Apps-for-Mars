#!/bin/sh
set -eu
APP_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/mars-focus-tests.XXXXXX")
trap 'rm -rf "$TEST_BUILD"' EXIT
xcrun swiftc -module-cache-path "$TEST_BUILD/module-cache" \
  "$APP_ROOT/MarsFocus/Models.swift" \
  "$APP_ROOT/MarsFocus/BlocklistStore.swift" \
  "$APP_ROOT/MarsFocus/SessionStore.swift" \
  "$APP_ROOT/MarsFocus/SessionNotifications.swift" \
  "$APP_ROOT/MarsFocus/CoachKeychain.swift" \
  "$APP_ROOT/MarsFocus/CoachService.swift" \
  "$APP_ROOT/tests/NativeRegressionTests.swift" \
  -o "$TEST_BUILD/native-tests"
"$TEST_BUILD/native-tests"
