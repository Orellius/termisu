#!/usr/bin/env bash
# A Rust staticlib carries Rust's precompiled standard library objects. Checking only the final
# Swift executable is too late: ld can warn and still produce an app that cannot launch on the
# deployment target advertised by the package.

set -euo pipefail

ARCHIVE="${1:-}"
MAXIMUM="${2:-13.0}"

if [ -z "$ARCHIVE" ] || [ ! -f "$ARCHIVE" ]; then
  echo "usage: $0 <static-library.a> [maximum-macos-version]" >&2
  exit 64
fi

LOAD_COMMANDS="$(mktemp "${TMPDIR:-/tmp}/termisu-macos-load-commands.XXXXXX")"
trap 'rm -f "$LOAD_COMMANDS"' EXIT
/usr/bin/otool -l "$ARCHIVE" > "$LOAD_COMMANDS"

STATUS=0
awk -v maximum="$MAXIMUM" '
  function version_code(version, parts) {
    split(version, parts, ".")
    return (parts[1] + 0) * 1000000 + (parts[2] + 0) * 1000 + (parts[3] + 0)
  }

  /\.a\(.+\):$/ { member = $0 }
  $1 == "minos" {
    found += 1
    if (version_code($2) > version_code(maximum)) {
      incompatible += 1
      if (incompatible <= 8) {
        printf "incompatible Mach-O member: %s requires macOS %s (maximum %s)\n", \
          member, $2, maximum > "/dev/stderr"
      }
    }
  }

  END {
    if (found == 0) {
      print "archive contains no Mach-O deployment metadata" > "/dev/stderr"
      exit 66
    }
    if (incompatible > 8) {
      printf "... and %d more incompatible Mach-O members\n", incompatible - 8 > "/dev/stderr"
    }
    if (incompatible) exit 65
  }
' "$LOAD_COMMANDS" || STATUS=$?
if [ "$STATUS" -ne 0 ]; then
  exit "$STATUS"
fi

COUNT="$(awk '$1 == "minos" { count += 1 } END { print count + 0 }' "$LOAD_COMMANDS")"
echo "validated $ARCHIVE: all $COUNT Mach-O members target macOS $MAXIMUM or earlier"
