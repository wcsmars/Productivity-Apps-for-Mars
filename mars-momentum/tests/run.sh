#!/usr/bin/env bash
set -euo pipefail
app_dir="$(cd "$(dirname "$0")/.." && pwd)"
node --check "$app_dir/MarsMomentumServer/server.mjs"
node --input-type=module --check < "$app_dir/MarsMomentumWeb/app.js"
node --check "$app_dir/MarsMomentumWeb/sync-core.mjs"
node --check "$app_dir/MarsMomentumWeb/storage-lock.mjs"
node --check "$app_dir/MarsMomentumWeb/document-store.mjs"
node --check "$app_dir/MarsMomentumWeb/sw.js"
node --test "$app_dir/tests/sync.test.mjs"

if [[ "$(uname -s)" == "Darwin" ]]; then
  regression_dir="$(mktemp -d "${TMPDIR:-/tmp}/mars-native-regression.XXXXXX")"
  trap 'rm -rf "$regression_dir"' EXIT
  xcrun swiftc -module-cache-path "$regression_dir/module-cache" \
    "$app_dir/MarsMomentum/Models.swift" \
    "$app_dir/MarsMomentum/Theme.swift" \
    "$app_dir/MarsMomentum/SyncClient.swift" \
    "$app_dir/MarsMomentum/EntryStore.swift" \
    "$app_dir/tests/NativeRegression.swift" \
    -o "$regression_dir/native-regression"
  "$regression_dir/native-regression"
else
  echo "Native regression checks require macOS and the Xcode toolchain."
fi
