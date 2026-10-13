#!/usr/bin/env bash
# Run Cargo through the official pinned Rust distribution. Homebrew's Rust standard library is
# built for the macOS version used by its bottle, so a static library built with it can silently
# stop supporting Termisu's declared deployment target even when the local crates use the right
# MACOSX_DEPLOYMENT_TARGET.

set -euo pipefail

TOOLCHAIN="${TERMISU_RUST_TOOLCHAIN:-1.97.1}"

if command -v rustup >/dev/null 2>&1; then
  RUSTUP="$(command -v rustup)"
elif command -v brew >/dev/null 2>&1 && BREW_RUSTUP_PREFIX="$(brew --prefix rustup 2>/dev/null)" \
  && [ -x "$BREW_RUSTUP_PREFIX/bin/rustup" ]; then
  RUSTUP="$BREW_RUSTUP_PREFIX/bin/rustup"
else
  echo "Termisu requires the official Rust $TOOLCHAIN toolchain through rustup." >&2
  echo "Install rustup, then run: rustup toolchain install $TOOLCHAIN --profile minimal" >&2
  exit 69
fi

if ! "$RUSTUP" toolchain list | grep -Eq "^${TOOLCHAIN}(-|[[:space:]])"; then
  echo "Rust toolchain $TOOLCHAIN is not installed." >&2
  echo "Run: $RUSTUP toolchain install $TOOLCHAIN --profile minimal" >&2
  exit 69
fi

CARGO_BIN="$("$RUSTUP" which cargo --toolchain "$TOOLCHAIN")"
RUSTC_BIN="$("$RUSTUP" which rustc --toolchain "$TOOLCHAIN")"
RUSTDOC_BIN="$("$RUSTUP" which rustdoc --toolchain "$TOOLCHAIN")"
TOOLCHAIN_BIN="$(dirname "$RUSTC_BIN")"

export PATH="$TOOLCHAIN_BIN:$PATH"
export RUSTC="$RUSTC_BIN"
export RUSTDOC="$RUSTDOC_BIN"

exec "$CARGO_BIN" "$@"
