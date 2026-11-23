#!/bin/bash
# Offline checks. They do not register a hotkey or write into another application.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cd "$root"
sources=()
for file in App/Sources/*.swift; do
    [[ "$file" == App/Sources/AppDelegate.swift ]] || sources+=("$file")
done
swiftc -emit-library -emit-module -enable-testing -module-name PinkVoicesCore \
    -emit-module-path "$stage/PinkVoicesCore.swiftmodule" "${sources[@]}" -o "$stage/libPinkVoicesCore.dylib"
for testfile in App/tests/*Check.swift; do
    # The visual HUD test opens macOS panels. Run it explicitly on a desktop.
    if [[ "$testfile" == */PinkHUDCheck.swift && "${PINK_VOICES_TEST_HUD:-0}" != 1 ]]; then continue; fi
    { echo '@testable import PinkVoicesCore'; cat "$testfile"; } > "$stage/Check.swift"
    swiftc -parse-as-library -I "$stage" -L "$stage" -lPinkVoicesCore \
        -Xlinker -rpath -Xlinker "$stage" "$stage/Check.swift" -o "$stage/check"
    "$stage/check" "$root/App/tests/fixtures/brand-context.json"
done
python="${PINK_VOICES_TEST_PYTHON:-$root/ASR/.venv/bin/python}"
serve="${PINK_VOICES_TEST_SERVE:-$root/ASR/model/serve}"
if [[ ! -x "$python" || ! -f "$serve/app.py" ]]; then
    echo 'Install the pinned ASR runtime first to run the Python tests.' >&2
    exit 1
fi
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$root/ASR:$serve" "$python" -m unittest discover -s ASR/tests
