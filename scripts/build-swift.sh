#!/usr/bin/env bash
# Builds the whole slice 8 chain and proves it: the Rust archive (with its 18-export
# check), then the Swift host against it, then the headless smoke -- a child's output
# becoming ink, reached exclusively through the C surface, from Swift.
#
# `swift build` runs from swift/ because Package.swift's -L flag resolves against the
# invoking directory.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT/scripts/build-host.sh" release

cd "$ROOT/swift"
# SwiftPM does not track the external Rust archive as a link input: a Rust-only change
# rebuilds libtermisu-vt-host.a and leaves the previously linked binary in place (caught
# 2026-07-29 -- the braille font fix built, the shipped app didn't have it). Deleting
# the product forces the relink; everything else stays incremental.
rm -f .build/release/termisu-host
swift build -c release

if [ "${1:-}" = "--no-smoke" ]; then
  exit 0
fi
.build/release/termisu-host --smoke

# Chrome geometry, the tab chords and the state marks. Pure arithmetic, no window, so it
# costs milliseconds. The band must hold exactly the top 52pt and the pane must start where
# it ends, down to a window shorter than the band; the island must clamp past the traffic
# lights and shrink to nothing on a narrow window rather than run off it. Carries its own
# control: a band of zero height passes every stacking assertion, so the pane's height in a
# 700pt window is checked absolutely.
.build/release/termisu-host --smoke-chrome

# What a program's TITLE says about whether it is working. Added 2026-08-26 because the
# table it checks was WRONG and nothing could see it: `classify` lived inside `Session`,
# reachable only from a session with a live pty, so it had never been asserted once. Two of
# the three spinner glyphs Claude Code puts in its title were missing, and the failure is
# silent and BACKWARDS - the chrome announced done while the agent was still working. The
# titles in it were captured off a real pty, not invented.
.build/release/termisu-host --smoke-workstate

# Mouse selection. The engine half is gated in Rust through the real C surface
# (crates/host/tests/selection_abi.rs); this is the host half, the click count and the
# cmd+C fallthrough, which no Rust test can see.
.build/release/termisu-host --smoke-selection

# The visual bell. BEL rang the system alert until 2026-08-26; it washes the pane that rang
# instead, because a chime says something needs you and says nothing about WHICH pane.
# The assertion that earns this gate is COALESCING: a wash per bell stacks their opacities,
# and a shell ringing in a loop -- a failing build script is the ordinary case -- would
# white the pane out and keep it white. Five mutants red, and one of them is the reason the
# colour is read off the LAYER and not off `BellFlash`: a systemRed wash passed the policy
# version of the achromatic check, which is exactly the stated limit of --smoke-chrome.
.build/release/termisu-host --smoke-bell

# The panel is the only part of Termisu that CAN reach the network, and this is what stops
# it. The README claims no network connections; the Rust half of that is
# crates/host/tests/no_network.rs, over the resolved dependency graph. This is the other
# half. `PanelNavigation` was extracted out of `decidePolicyFor` to make it reachable at
# all: `WKNavigationAction` has no public initialiser, so the policy had never been
# asserted once. Four mutants red, and one of them found a real hole rather than a missing
# assertion -- without the `isFileURL` guard, `https://evil.example/<document path>`
# resolves to the document path and the panel loads a remote origin.
.build/release/termisu-host --smoke-offline

# SSH hosts. Parses a fixture ssh_config it writes itself - never the operator's, because
# ~/.ssh is a credential directory and a gate that read it would print its contents into
# CI output the first time it failed. The discriminating cases are the ones a naive line
# splitter gets wrong: a wildcard pattern is not a host, a duplicate block must LOSE to
# first-value-wins, a Match block's keys must not stick to the host above it. All three
# mutants seen red 2026-08-14, each with its own message. Carries its own control: a
# missing config must read as an empty list, not as a failure.
.build/release/termisu-host --smoke-ssh

# The connection form's WRITER, and it guards a mutation of a file this app did not author
# rather than a feature, so its assertions are about damage. The load-bearing one is shell
# quoting: the host runs a pane's command through `/bin/sh -c`, so an alias carrying a
# semicolon runs as two commands, and no validator upstream has any reason to reject a
# semicolon. It is proven against `/bin/sh` itself - five payloads re-split by a real shell
# must come back as the same five words - because inspecting the quoting proves nothing
# about what the shell does with it. Next after that: a newline in ANY field would append a
# second block to the operator's ssh config, a refused write must leave the file
# byte-identical, and a fresh config must be 0600. Mutants seen red 2026-08-14: a naive
# join, a disabled newline check, an allowed duplicate alias, a truncate instead of an
# append, a 0644 create, and the form's Port and User fields swapped.
.build/release/termisu-host --smoke-ssh-write

# The connection dialog's GEOMETRY, and it exists because v0.28.0 shipped this form with
# two controls collapsed to 0pt and a dialog 590pt tall hanging off an 816x510 window,
# with all five gates green. The gates stop at Session by design, so nothing above it was
# ever measured. What makes this one able to see the defect is WHERE it is rooted: the
# form measured on its own reports every field at a correct 320pt in the broken build,
# because the collapse happens when the container re-frames it. It walks the container's
# tree instead, and asserts the height against a ceiling derived from the smallest window
# this host opens. Faults are reported together, not one per build.
#
# `--shot-ssh-dialog <path>` beside it renders the same dialog to a PNG. Not a gate: an
# assertion cannot answer "does it look right", and that question is what found this.
.build/release/termisu-host --smoke-ssh-layout

# Split tiling. Pure arithmetic, no window, no pty -- `SplitLayout` exists apart from the
# views for exactly the reason `ChromeLayout` does. The failure it guards is silent: a
# tiling one point out looks fine at 1120 and leaves a seam, or an overlap, at 300. It
# checks POINT COVERAGE on a lattice rather than summing areas, because an area sum is
# satisfied by a tiling that loses a column here and gains one there, and it feeds
# fractional rects because a real content rect is one - with whole numbers only, removing
# the integralisation changes nothing and the gate cannot see it (measured: that mutant
# survived the first version of this gate). Three things exact tiling CANNOT see are
# asserted separately: first is top, divider indices agree with the walk, and focus is
# geometric rather than tree-shaped.
.build/release/termisu-host --smoke-split
.build/release/termisu-host --smoke-blocks

# What closing the LAST pane does. cmd+W on the last tab opens a fresh shell; a child that
# exited on its own still quits. Both rows are asserted because respawning unconditionally
# satisfies the ask and leaves the app impossible to quit by typing `exit`.
.build/release/termisu-host --smoke-lastpane

# S5 workspaces. The load-bearing assertion is the REFUSAL: remove() never passes
# --force, and a dirty worktree surviving is what stands between this feature and
# deleting an agent's unpushed work. Mutant seen red (adding --force fails it).
.build/release/termisu-host --smoke-worktree

# Agents. The load-bearing assertion is again the refusal: an approval-bypassing flag must
# come back REFUSED AND NAMED, through the Swift argv borrow, before anything is spawned. A
# fake agent on PATH, never a real one -- a build gate must not start authenticated agent
# processes on the machine it runs on.
#
# Two mutants seen red: collapsing the refusal into a generic failure (the operator stops
# being told which word to remove), and letting the argv borrow dangle - which does not crash,
# it lets `--yolo` through the guard entirely.
.build/release/termisu-host --smoke-agent

# P1 file panel, the policy half: every path the panel sends is untrusted and names a
# file on this disk. Ways out (.., absolute, NUL, a symlink outside) must be refused next
# to ways that must still work (a symlink inside, a root behind a symlink), because a
# boundary that refuses everything passes every refusal assertion.
.build/release/termisu-host --smoke-files

# S6 panels. The web build is optional (no bun, no panels), so its absence SKIPS the
# probe out loud instead of leaving a silently unproven seam. Both directions run: the
# probe must round-trip a nonce, and the control -- the same document with the receiver
# removed -- must load, mount, and fail to answer. The control is the half that matters;
# on its first run it passed for the wrong reason and hid a real navigation-policy bug.
if "$ROOT/scripts/build-web.sh"; then
  .build/release/termisu-host --smoke-panel --web-dir "$ROOT/web/dist"
  .build/release/termisu-host --smoke-panel-control --web-dir "$ROOT/web/dist"
  # P1 file panel, the document half: a Rust and a Markdown file opened through the
  # bridge, coloured by their grammars (tokenize, since a hidden window paints nothing)
  # with the blob worker running and the icon font loaded. The control strips
  # `worker-src blob:` and `font-src data:` and must see both blocked, so each "ok" is
  # shown to depend on its CSP line.
  .build/release/termisu-host --smoke-file-panel --web-dir "$ROOT/web/dist"
  .build/release/termisu-host --smoke-file-panel-control --web-dir "$ROOT/web/dist"
else
  status=$?
  [ "$status" -eq 2 ] || exit "$status"
  echo "[SKIPPED: panel bridge smoke - no web build]" >&2
fi
