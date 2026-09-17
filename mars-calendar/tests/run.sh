#!/bin/sh
set -eu

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/mars-calendar-tests.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM

xcrun swiftc -module-cache-path "$build_dir/module-cache" \
  "$test_dir/../MarsCalendar/Models.swift" \
  "$test_dir/../MarsCalendar/QuickParse.swift" \
  "$test_dir/../MarsCalendar/TemplateStore.swift" \
  "$test_dir/QuickParseTests.swift" \
  -o "$build_dir/QuickParseTests"
"$build_dir/QuickParseTests"
