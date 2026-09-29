#!/bin/sh
# Compiles and runs the standalone CodeBurn checks (the Xcode project has no test target).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
C="$ROOT/scripts/codeburn-checks"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

swiftc -parse-as-library -o "$OUT/payload" \
  "$C/Check.swift" "$C/PayloadCheck.swift" "$ROOT/boringNotch/models/CodeBurnPayload.swift"
"$OUT/payload" "$C"

swiftc -parse-as-library -o "$OUT/runner" \
  "$C/Check.swift" "$C/RunnerCheck.swift" "$ROOT/BoringNotchXPCHelper/CodeBurnRunner.swift"
"$OUT/runner"
