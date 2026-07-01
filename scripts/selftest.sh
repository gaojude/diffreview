#!/bin/bash
# Fast logic self-test. No Xcode UI, no permissions — CI-friendly.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/_env.sh"
swift run -c release MyIDESelfTest
