#!/bin/sh
set -eu
TEST_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
"$TEST_ROOT/run-native.sh"
node --check "$TEST_ROOT/../MarsFocusWeb/app.js"
node --check "$TEST_ROOT/../MarsFocusWeb/storage-lock.js"
node --test "$TEST_ROOT/service-worker.test.cjs" "$TEST_ROOT/web-state.test.cjs"
