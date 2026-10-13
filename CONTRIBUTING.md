# Contributing to Termisu

Thanks for looking. This project has an unusual testing culture and it is the main thing a
new contributor needs to understand, so it comes first.

## The one rule: a test must be seen to fail

Every gate in this repository has been run against a deliberately broken version and watched
go red. A test that has never been red is not evidence, and a guard is never proven by the
absence of what it suppresses.

In practice that means two directions, not one:

1. Feed the check the input it exists to catch, and watch it fire.
2. Feed it the neighbouring input it must NOT catch, and watch it stay quiet.

If you cannot make your new test fail, the test is the thing that is broken.

## Extend the harness before you change behaviour

Ten slices in a row have had a blind spot the existing tests could not see, and several were
total: a wrong implementation would have scored a perfect match on the entire corpus. Before
writing the change, ask what new observable the harness needs. Some real examples:

- Scrollback was invisible because the snapshot held only the active area.
- Resize was not expressible at all until the corpus case format gained a `resize` field.
- Selection could not be represented, so a `select_word` returning the whole screen would
  have matched on every case.
- The renderer had no pixel test, so a renderer that drew nothing satisfied everything.

## The differential corpus

`corpus/cases.toml` is the contract. Each case is a byte stream plus the verdict it is
asserted to produce when our grid is compared against the real `libghostty-vt`.

A case pinned `expect = "diff"` is a to-do, not a pass. When you implement that behaviour the
case *fails*, and promoting it to `expect = "match"` is the evidence your change worked. The
corpus deliberately keeps cases in both directions, because a harness that cannot detect
disagreement proves nothing.

`oracle.lock` pins the exact reference commit the verdicts were measured against. Commit it
whenever it moves, so a verdict flipping overnight can be told apart from a regression you
caused.

## Read the reference source, do not infer it

Probing establishes WHAT differs. The reference implementation's source explains WHY, and
several rules here were only ever settled that way. One example that is now load-bearing: the
reference's own doc comment for word selection is wrong, and its code is the contract.

## GUI-facing work needs a live tap

Anything whose contract ends at the GUI (a click, a chord, a drag, a resize) is not proven by
a headless test. The demo that works when a harness drives bytes routinely dies when a human
drives the window. Either drive synthesized input into a real window, or say plainly in the
PR that the seam is untested and name it.

Aesthetic judgements are not something a test settles. Say `untested` and attach a screenshot.

## Gates

All five are exit-code gates. Run them before you open a pull request.

```sh
./scripts/cargo.sh test --workspace             # units, pixels, concurrency, C-surface round trips
./scripts/cargo.sh run -p termisu-vt-difftest  # corpus, against the real reference library
./scripts/build-lib.sh                         # libtermisu-vt.a, exports and deployment target
./scripts/build-swift.sh                       # host archive, Swift host and headless smoke stages
./scripts/check-macos-deployment-target-tests.sh # accepts macOS 13 and rejects macOS 26
```

`scripts/build-swift.sh` deliberately runs the Swift host smoke stages headlessly. It proves the
host archive, C surface, process launch, layout, input, offline policy and persistence seams
without taking over the operator's screen.

## Development setup

Rust 1.97.1 through `rustup`, edition 2024, resolver 3. The exact official toolchain is pinned
because Homebrew's precompiled Rust standard library inherits the bottle's macOS deployment
target and can make Termisu's static archives require a newer OS than the app declares. The
archives target macOS 13; the app itself needs macOS 26, because its tab bar is SwiftUI glass.
macOS on Apple Silicon is the developed and tested platform today; the core, frame, render and
difftest crates are portable and other platforms are welcome work.

The differential harness needs a Ghostty checkout to build its oracle from:

```sh
TERMISU_VT_ORACLE_SRC=/path/to/ghostty ./scripts/build-oracle.sh
```

That checkout is treated as read-only. The script redirects both the build prefix and the
cache directory into this repository and then verifies the checkout is still clean, failing
if it is not. It requires Zig 0.16.0 exactly.

`scripts/fetch-esctest.sh` vendors the esctest2 conformance suite, pinned in `esctest.lock`.
`scripts/fetch-ucd.sh` vendors the Unicode bidi conformance data, pinned in `ucd.lock`.

## Style

- Rust: `Result` and `thiserror` for expected failures, `panic!` only for bugs, every
  `unsafe` block justified in a comment that names what would go wrong without it.
- `cargo fmt --all` reformats the whole repository, which was never rustfmt-clean. Format only
  the files your change actually touches, or the diff drowns.
- Comments explain the failure a rule prevents. An idiom with no stated failure mode is cargo
  cult and will be asked about in review.
- Commit messages explain WHY, not what the diff already shows.

## Pull requests

Work lands on `main`, one commit per verified seam. A pull request should state:

- which gates were run and their numbers,
- which mutant was used to prove any new test can fail,
- for GUI-facing work, whether it was live-tapped or is explicitly untested.

Behaviour that deliberately diverges from the reference implementation is fine, and there are
several such divergences already. It has to be recorded as a pinned corpus case with the
reason, never left as an undocumented difference.

## Licensing of contributions

Termisu is [AGPL-3.0-only](LICENSE). By contributing you agree that your contribution is
licensed under the same terms. There is no CLA.

Do not paste code from other terminal emulators into this repository, whatever their licence.
The reference implementation is used as a measuring instrument at test time and no line of it
ships here, which is a property worth keeping true.
