#!/usr/bin/env bash
# Builds the embedder artifact: libtermisu-vt-host.a.
#
# One archive, both surfaces: the host crate depends on termisu-vt-abi as an rlib, which
# carries the 13 `ghostty_*` exports in alongside the 5 `termisu_host_*` ones. Two Rust
# staticlibs cannot share a link (each would bring its own copy of the Rust runtime), so
# the Swift host links this single archive. The pure drop-in `libtermisu-vt.a` remains
# `scripts/build-lib.sh`'s separate, slim artifact.
#
# The rename exists for the same reason as in build-lib.sh: cargo cannot emit a hyphenated
# archive name, and the link flag should read like the ghostty one does.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-release}"
DEPLOYMENT_TARGET="${TERMISU_MACOS_DEPLOYMENT_TARGET:-13.0}"
BUILD_ROOT="$ROOT/target/macos-$DEPLOYMENT_TARGET"
cd "$ROOT"

case "$PROFILE" in
  release) CARGO_TARGET_DIR="$BUILD_ROOT" MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    "$ROOT/scripts/cargo.sh" \
    build --release -p termisu-vt-host ;;
  debug)   CARGO_TARGET_DIR="$BUILD_ROOT" MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    "$ROOT/scripts/cargo.sh" \
    build -p termisu-vt-host ;;
  *) echo "usage: $0 [release|debug]" >&2; exit 2 ;;
esac

OUT="target/$PROFILE"
SRC="$BUILD_ROOT/$PROFILE/libtermisu_vt_host.a"
DST="$OUT/libtermisu-vt-host.a"

if [ ! -f "$SRC" ]; then
  echo "cargo did not produce $SRC" >&2
  exit 1
fi
mkdir -p "$OUT"
cp "$SRC" "$DST"
"$ROOT/scripts/check-macos-deployment-target.sh" "$DST" "$DEPLOYMENT_TARGET"

# Both surfaces, by name. A host archive that lost a ghostty_* symbol has silently stopped
# carrying the VT readout; one that lost a termisu_host_* symbol fails at the Swift link,
# which is the worst place to find out.
EXPECTED=(
  ghostty_terminal_new
  ghostty_terminal_free
  ghostty_terminal_vt_write
  ghostty_terminal_resize
  ghostty_terminal_get
  ghostty_terminal_mode_get
  ghostty_terminal_grid_ref
  ghostty_grid_ref_cell
  ghostty_grid_ref_row
  ghostty_grid_ref_graphemes
  ghostty_grid_ref_style
  ghostty_cell_get
  ghostty_row_get
  ghostty_style_default
  termisu_host_spawn
  termisu_host_poll
  termisu_host_send
  termisu_host_paste
  termisu_host_mouse_geometry
  termisu_host_mouse
  termisu_host_wheel
  termisu_host_key
  termisu_host_scroll
  termisu_host_resize
  termisu_host_cell_metrics
  termisu_host_set_font_size
  termisu_host_row_text
  termisu_host_link_at
  termisu_host_path_at
  termisu_host_link_span_at
  termisu_host_select_word_at
  termisu_host_select_line_at
  termisu_host_select_to
  termisu_host_select_all
  termisu_host_select_clear
  termisu_host_selection_text
  termisu_host_next_event
  termisu_host_free
  termisu_history_load
  termisu_history_free
  termisu_history_append
  termisu_history_suggest
  termisu_cwd_path
  termisu_workflows_load
  termisu_workflows_free
  termisu_workflows_count
  termisu_workflows_errors
  termisu_workflow_field
  termisu_workflow_arg_count
  termisu_workflow_arg
  termisu_workflow_render
  termisu_config_load
  termisu_config_font_size
  termisu_config_auto_direction
  termisu_config_shell
  termisu_config_reports
  termisu_config_panels
  termisu_config_font_family
  termisu_config_error
  termisu_config_free
  termisu_host_attach_layer
  termisu_host_detach_layer
  termisu_host_resize_layer
  termisu_host_present
  termisu_agent_count
  termisu_agent_info
  termisu_agent_resolve
  termisu_agent_screen
  termisu_host_spawn_agent
)

# Captured once, not piped per symbol: `nm` exits non-zero on members with no symbols, and
# under pipefail that once reported every export missing while all were present.
SYMBOLS="$(mktemp)"
trap 'rm -f "$SYMBOLS"' EXIT
nm -gU "$DST" 2>/dev/null > "$SYMBOLS" || true

MISSING=0
for symbol in "${EXPECTED[@]}"; do
  if ! grep -q " _${symbol}$" "$SYMBOLS"; then
    echo "MISSING export: $symbol" >&2
    MISSING=1
  fi
done
if [ "$MISSING" -ne 0 ]; then
  exit 1
fi

echo "built $DST with all ${#EXPECTED[@]} exports"
