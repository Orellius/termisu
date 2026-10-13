#!/usr/bin/env bash
# Control both sides of the deployment gate with tiny real Mach-O archives. The macOS 26 fixture
# is the exact failure shape previously carried by Homebrew's precompiled Rust standard library.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/termisu-deployment-gate-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

/usr/bin/xcrun clang -target arm64-apple-macos13.0 -x c -c /dev/null -o "$WORK/macos13.o"
/usr/bin/xcrun clang -target arm64-apple-macos26.0 -x c -c /dev/null -o "$WORK/macos26.o"
/usr/bin/ar rcs "$WORK/compatible.a" "$WORK/macos13.o"
/usr/bin/ar rcs "$WORK/incompatible.a" "$WORK/macos13.o" "$WORK/macos26.o"

"$ROOT/scripts/check-macos-deployment-target.sh" "$WORK/compatible.a" 13.0

if "$ROOT/scripts/check-macos-deployment-target.sh" "$WORK/incompatible.a" 13.0 \
  > "$WORK/rejection.txt" 2>&1; then
  echo "deployment gate accepted an archive containing a macOS 26 object" >&2
  exit 1
fi

if ! grep -q "requires macOS 26.0 (maximum 13.0)" "$WORK/rejection.txt"; then
  echo "deployment gate rejected the control without naming the incompatible target" >&2
  exit 1
fi

echo "deployment target gate tests passed"
