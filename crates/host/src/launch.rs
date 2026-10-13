//! Purpose: starting an agent CLI in a pane and KNOWING whether it started.
//! Public surface: `Verdict`, `Attempt`, `Launched`, `LaunchError`, `into_pane`, `observe`.
//! Why this file: this is the wedge, and it is one function call rather than a parser. Everyone
//!   else in this category watches an agent by scraping bytes out of a pty stream; we own the VT
//!   core, so "did it start" is a question asked of the TYPED GRID - `Session::visible_text` over
//!   the last drawn frame. No regex, no ANSI, no byte budget, and it cannot be confused by an
//!   agent that repaints its banner or clears the screen.
//! NOT responsible for: what the agent then DOES (B5 fuses grid semantics, CLI hooks and process
//!   polling into a state machine), stopping it (B4.3), or picking which agent goes where.
//! Test strategy: fakes for the machinery, one real agent for the claim. The state machine is
//!   proven with `/bin/sh` children whose behaviour is exactly specifiable - dies instantly,
//!   lives but says nothing, says something then dies, says something and stays - because those
//!   four are the whole truth table and a real CLI can only ever demonstrate one of them per run.
//!   The real-agent launch is a separate `#[ignore]`d test, run by hand: an automated suite must
//!   not start authenticated agent processes on someone's machine every time it runs.

use std::process::Command;
use std::thread::sleep;
use std::time::{Duration, Instant};

use crate::session::{Session, SessionError};
use termisu_vt_render::GpuContext;

use crate::agent::{AgentDef, Dangerous, launch};

/// What the pane's child turned out to be doing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    /// It wrote something and was still alive afterwards. This is the only success.
    Running,
    /// Alive for the whole grace window and never wrote a byte. A wrong binary, a hung network
    /// call at startup, a CLI waiting on a tty it does not think it has.
    Silent,
    /// It exited during the grace window. `wrote` separates the two flavours, and they are
    /// different bugs: silence then exit is usually a missing binary or a failed auth, while
    /// output then exit is the CLI printing usage or an error and giving up.
    Exited { wrote: bool },
}

/// One attempt, kept so a retry loop can be SEEN to have run rather than assumed to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Attempt {
    pub index: u32,
    pub verdict: Verdict,
    /// How long this attempt was observed for.
    pub took: Duration,
    /// How long we waited BEFORE starting it. Zero for the first.
    pub backoff: Duration,
}

/// A started agent, with the history of getting there.
pub struct Launched {
    pub session: Session,
    pub attempts: Vec<Attempt>,
}

/// Shows the attempts and nothing else: a `Session` owns a pty, a child and a GPU surface, none
/// of which has a useful debug rendering and all of which would bury the one thing a failure
/// message needs - what happened on each try.
impl std::fmt::Debug for Launched {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Launched")
            .field("attempts", &self.attempts)
            .finish_non_exhaustive()
    }
}

#[derive(Debug)]
pub enum LaunchError {
    /// The operator's argv carried an approval bypass. Refused, never stripped.
    Refused(Dangerous),
    /// Every attempt failed; the verdicts say how.
    Failed(Vec<Attempt>),
    Session(SessionError),
}

/// How long a child must stay alive after its first output before we believe it.
///
/// Without it, a CLI that prints usage and exits is `Running` for the microsecond between the
/// write and the exit - and which side of that race a poll lands on is luck. With it, "it wrote
/// and it is still there" is a claim about a span rather than an instant.
const SETTLE: Duration = Duration::from_millis(250);

/// How often the session is polled while waiting. The pump publishes on its own thread; this is
/// only how quickly we notice.
const TICK: Duration = Duration::from_millis(10);

/// Watches a freshly spawned session until it proves itself or the grace window ends.
///
/// The output test is `visible_text` - the drawn grid, not the byte stream. An agent that clears
/// the screen and repaints, or that switches to the alternate screen, still moves the grid; a
/// byte-counting version of this would also "see" output that was nothing but a cursor query.
pub fn observe(session: &mut Session, grace: Duration) -> Verdict {
    let deadline = Instant::now() + grace;
    let mut wrote_at: Option<Instant> = None;

    loop {
        session.poll();
        let wrote = !session.visible_text().trim().is_empty();
        if wrote && wrote_at.is_none() {
            wrote_at = Some(Instant::now());
        }
        // Death is checked BEFORE success, so a child that wrote and then quit is reported as
        // what it is rather than caught mid-race as Running.
        if session.exited() {
            return Verdict::Exited { wrote };
        }
        if wrote_at.is_some_and(|at| at.elapsed() >= SETTLE) {
            return Verdict::Running;
        }
        if Instant::now() >= deadline {
            return if wrote {
                // It wrote inside the window and is alive; the settle simply had not elapsed.
                Verdict::Running
            } else {
                Verdict::Silent
            };
        }
        sleep(TICK);
    }
}

/// Starts `agent` in a pane of `width` x `height` physical pixels, retrying on failure.
///
/// Backoff is exponential from `base` and the waits are RECORDED, because a retry loop nobody
/// can see is the SCAR-004 shape - it looks identical whether it ran three times or never ran at
/// all. Every attempt's verdict and its preceding wait come back with the session, and the tests
/// assert on them rather than on "it worked in the end".
pub fn into_pane(
    gpu: &GpuContext,
    agent: &'static AgentDef,
    binary: &str,
    extra: &[String],
    cwd: Option<&str>,
    size: (u32, u32),
    font_size: f32,
    tries: u32,
    base: Duration,
) -> Result<Launched, LaunchError> {
    let mut attempts = Vec::new();

    for index in 0..tries.max(1) {
        // Doubling from the base: 0, base, base*2, base*4. The first attempt never waits - a
        // backoff before the first try is latency charged for nothing.
        let backoff = if index == 0 {
            Duration::ZERO
        } else {
            base * 2u32.pow(index - 1)
        };
        if !backoff.is_zero() {
            sleep(backoff);
        }

        let mut command = launch(agent, binary, extra).map_err(LaunchError::Refused)?;
        if let Some(cwd) = cwd {
            seat(&mut command, std::path::Path::new(cwd));
        }
        // Fitted, never spawned-then-resized: an agent that prints a banner or a table sized on
        // startup bakes the wrong width into scrollback, where no later resize can reach it.
        let mut session =
            Session::spawn_fitted_on(gpu, command, size.0, size.1, font_size, None)
                .map_err(LaunchError::Session)?;

        let started = Instant::now();
        let verdict = observe(&mut session, agent.spawn_grace);
        attempts.push(Attempt {
            index,
            verdict,
            took: started.elapsed(),
            backoff,
        });

        if verdict == Verdict::Running {
            return Ok(Launched { session, attempts });
        }
        // A failed attempt's child is reaped here rather than left to a destructor further up:
        // the next attempt spawns another one, and two agents holding the same worktree is a
        // problem that surfaces as file corruption rather than as an error (SCAR-016 discipline -
        // reach the cleanup path deliberately).
        session.shutdown();
    }

    Err(LaunchError::Failed(attempts))
}

/// What every child spawned into a pane is handed, in ONE place.
///
/// EXTRACTED 2026-08-08 because it was not in one place, and the consequence was live: a real
/// `claude` launched into a pane reported "Transcript saving is off - inherited
/// CLAUDE_CODE_CHILD_SESSION marker". The rule existed and was correct; it just lived inside
/// `main.rs`'s `shell_from`, and three other places built a `Command` without it - this module's
/// own `shell_command`, `agent::launch`, and the probe host. Exactly the shape that had already
/// cost this project the font-family bug: a rule applied on one path and silently absent on the
/// rest.
///
/// TERM IS DECLARED, NEVER PASSED THROUGH. An app launched from Finder inherits no environment,
/// so a child handed an empty TERM finds no terminfo entry and every ncurses program exits before
/// drawing a cell. That is what "no CLI can run in here" looks like from outside, and it is
/// invisible whenever the app is started from a terminal that already had one set.
///
/// A TERMINAL WINDOW IS A SESSION BOUNDARY. `CLAUDECODE` and `CLAUDE_CODE_CHILD_SESSION` are
/// removed so an agent CLI opened in a pane is its own session rather than a child of whatever
/// launched Termisu. Leaving them set does not fail loudly - the agent starts, and quietly turns
/// off transcript saving.
pub fn dress(command: &mut Command) {
    // A TERMINAL WINDOW MEANS "A SHELL AT HOME", and without this it means "a shell wherever the
    // app happened to be launched from". A Finder-launched app inherits `/`, so the pane opens on
    // the sealed read-only root - which starship dresses in a padlock, and which the operator
    // read as a permission block. That was seen live on 2026-07-30, fixed in the C ABI host, and
    // never carried across to this one; the maintainer hit it again on 2026-08-08 as "why does the terminal
    // not start at ~".
    //
    // Set FIRST, so a caller with a real destination (a worktree, a spec) overrides it simply
    // by calling `seat` afterwards and without having to know this default exists. `seat`,
    // never a bare `current_dir`: the port block is derived from where the child sits, and a
    // caller that moves it without re-deriving leaves every workspace on the home block.
    //
    // A HOME that is not a directory is ignored rather than fatal: `Command::spawn` reports a bad
    // cwd as a plain ENOENT from the exec, indistinguishable from a missing shell, and a terminal
    // should open somewhere usable rather than fail with a misleading error.
    if let Ok(home) = std::env::var("HOME")
        && std::path::Path::new(&home).is_dir()
    {
        seat(command, std::path::Path::new(&home));
    }
    command.env("TERM", CHILD_TERM);
    // Declared for the same reason as TERM rather than merely echoed: without it a program that
    // checks for truecolor falls back to 256 colours in a terminal that has had 24-bit colour
    // since slice 1.
    command.env("COLORTERM", "truecolor");
    // Declared for the same reason again: this terminal renders OSC 8 hyperlinks, but a program
    // cannot ask, so the `supports-hyperlinks` convention guesses from TERM_PROGRAM and turns
    // links off for any name it does not know. Claude Code 2.1.283 follows it and printed every
    // URL as plain text here (measured 2026-09-29, P0 of the agent workspace plan).
    // FORCE_HYPERLINK is the override that convention reads first.
    command.env("FORCE_HYPERLINK", "1");
    command.env_remove("CLAUDECODE");
    command.env_remove("CLAUDE_CODE_CHILD_SESSION");
}

/// The lowest port any workspace block starts at.
///
/// Above every default a dev tool reaches for (3000, 5432, 8080) and far below the
/// ephemeral range macOS hands out to outbound sockets, which starts at 49152 -- a block up
/// there would collide with ports the kernel is also giving away.
pub const PORT_LOW: u16 = 20000;

/// How many ports one workspace owns. A web server, an API, a database and a cache is four.
pub const PORT_SPAN: u16 = 10;

/// How many blocks the band holds, so the top of the band is 39990.
///
/// The collision arithmetic, because a hash has no other kind of guarantee: with N
/// workspaces the chance any two share a block is about `1 - exp(-N(N-1)/2/BLOCKS)`. At the
/// four to eight worktrees this feature exists for that is 0.3% to 1.4%. It is not zero, and
/// pretending otherwise would need a registry file, which is state on disk that has to be
/// cleaned up and is wrong the moment a worktree is moved.
pub const PORT_BLOCKS: u16 = 2000;

/// The first port of the block belonging to `workspace`.
///
/// **Derived from the path, never handed out in sequence.** A base assigned in launch order
/// moves whenever the panes open in a different order, and then a bookmark, a proxy rule and
/// a database URL all rot. This way the same worktree is the same block forever, on every
/// machine, with no state kept anywhere.
///
/// FNV-1a written out here rather than `DefaultHasher`, and that is load-bearing:
/// `RandomState` is seeded per process, so `DefaultHasher` would hand out a different block
/// on every launch, and `SipHasher`'s unseeded output is explicitly not guaranteed stable
/// across Rust releases. This one is pinned by `tests/port_base.rs` to exact values.
///
/// The path is canonicalized when that succeeds, so a worktree reached through a symlink is
/// the same workspace as the worktree itself -- on macOS `/tmp` is a symlink to
/// `/private/tmp`, which would otherwise be two workspaces. When it fails, which is the
/// ordinary case for a directory that does not exist yet, the literal path is used with any
/// trailing separators trimmed.
pub fn port_base(workspace: &std::path::Path) -> u16 {
    let resolved = workspace.canonicalize();
    let text = match &resolved {
        Ok(real) => real.to_string_lossy(),
        Err(_) => workspace.to_string_lossy(),
    };
    let trimmed = text.trim_end_matches('/');

    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in trimmed.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }

    // FNV-1a ALONE IS NOT ENOUGH HERE, and both obvious ways of taking a bucket out of it
    // were measured failing on 2026-08-26 against the case this feature is for: 64 sibling
    // worktrees whose paths differ only in the last byte, `feature-1`, `feature-2`.
    //
    //   `hash % PORT_BLOCKS`  -> 54 distinct blocks out of a fair 63. The last byte lands in
    //                            the low bits and one multiply barely mixes them.
    //   high half of the hash -> 3. Worse, and for the mirror reason: the final multiply
    //                            carries the last byte upward hardly at all.
    //
    // So the fix is an avalanche step, not a different slice of the same bits. This is
    // MurmurHash3's `fmix64`, whose whole job is to make every input bit reach every output
    // bit, followed by a multiply-shift bucket rather than a modulo so the result is
    // unbiased even when `PORT_BLOCKS` does not divide 2^64.
    hash ^= hash >> 33;
    hash = hash.wrapping_mul(0xff51_afd7_ed55_8ccd);
    hash ^= hash >> 33;
    hash = hash.wrapping_mul(0xc4ce_b9fe_1a85_ec53);
    hash ^= hash >> 33;

    PORT_LOW + ((u128::from(hash) * u128::from(PORT_BLOCKS)) >> 64) as u16 * PORT_SPAN
}

/// Puts a child in a directory, and hands down everything derived from being there.
///
/// **The one place a spawned child's directory is set**, for exactly the reason `dress` is
/// the one place its environment is set. Four call sites used to reach for `current_dir`
/// directly, and the moment anything is derived from the directory - a port block, a PWD -
/// a fifth caller that forgets is a bug that only shows up in one spawn path. That is the
/// defect shape this project has now paid for four times.
pub fn seat(command: &mut Command, workspace: &std::path::Path) {
    command.current_dir(workspace);
    // NOT REDUNDANT with `current_dir`. That changes the process's directory and leaves the
    // INHERITED `PWD` naming the parent's, so a shell builtin `pwd` - which prefers the
    // variable - reports the wrong answer until something reassigns it. A login zsh does
    // reassign it, which is what makes this appear only under the one shell that does not.
    command.env("PWD", workspace);

    // The port block. Four to eight agents in four to eight worktrees all want 3000, and the
    // one that loses reports a broken build that is not broken.
    //
    // `PORT` ITSELF IS DELIBERATELY NOT SET. Silently moving a dev server off the port its
    // operator typed is a bigger surprise than a variable nothing reads yet, and the formula
    // the ecosystem already passes around - `BASE + INDEX * 10 + OFFSET` - wants a base.
    let base = port_base(workspace);
    command.env("TERMISU_PORT_BASE", base.to_string());
    command.env("TERMISU_PORT_SPAN", PORT_SPAN.to_string());
}

/// The terminal type every pane declares.
pub const CHILD_TERM: &str = "xterm-256color";

/// The command a pane would run for a plain shell, for callers mixing shells and agents.
///
/// `-l` for the same reason `shell_from` passes it: a shell with a pty on stdin is INTERACTIVE
/// already, so `.zshrc` was always sourced, but without `-l` neither `/etc/zprofile` (path_helper)
/// nor `~/.zprofile` (homebrew's shellenv) runs, and the pane's PATH is whatever launched the app.
pub fn shell_command() -> Command {
    let path = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
    let mut command = Command::new(path);
    command.arg("-l");
    dress(&mut command);
    command
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::{LaunchError, Verdict, into_pane};
    use crate::agent::{AgentDef, Prompt, Resume};

    const SIZE: (u32, u32) = (640, 320);
    const FONT: f32 = 16.0;

    /// A fake agent whose "binary" is a shell script the test writes itself. The registry entry
    /// is real in shape - the same struct the host uses - so the machinery under test is the
    /// machinery that ships; only the child is specifiable.
    fn fake(grace_ms: u64) -> AgentDef {
        AgentDef {
            id: "fake",
            name: "Fake",
            candidates: &["sh"],
            default_args: &[],
            prompt: Prompt::Inline("{command} {prompt}"),
            auto_approve: None,
            spawn_grace: Duration::from_millis(grace_ms),
            idle: None,
            resume: Resume::None,
            install_hint: "-",
        }
    }

    fn argv(words: &[&str]) -> Vec<String> {
        words.iter().map(|word| word.to_string()).collect()
    }

    /// The whole truth table, in one test, because the four cases are only meaningful against
    /// each other: a verdict function that always said `Running` would pass any single one of
    /// them and none of the rest.
    #[test]
    fn every_shape_of_a_child_gets_its_own_verdict() {
        let agent: &'static AgentDef = Box::leak(Box::new(fake(600)));
        let gpu = termisu_vt_render::GpuContext::new().expect("a GPU");

        let cases: &[(&str, Verdict)] = &[
            // Speaks and stays. The only success.
            ("printf 'hello from the agent\\n'; exec cat", Verdict::Running),
            // Alive and mute for the whole window: a hung startup, or a CLI waiting on something.
            // `exec sleep`, deliberately - the first version of this line was
            // `exec cat < /dev/null; sleep 30`, where the exec REPLACES the shell with a cat that
            // hits EOF at once, so the child died and the sleep never ran. It scored
            // `Exited { wrote: false }` and the fixture, not the code, was wrong.
            ("exec sleep 30", Verdict::Silent),
            // Dies instantly with nothing said: the missing-binary and failed-auth shape.
            ("exit 1", Verdict::Exited { wrote: false }),
            // Prints its usage and gives up. Reported as an exit, NOT as a success, which is the
            // case a naive "did anything appear on the grid" check gets wrong.
            ("printf 'usage: fake [options]\\n'; exit 2", Verdict::Exited { wrote: true }),
        ];

        for (script, want) in cases {
            let result = into_pane(
                &gpu,
                agent,
                "/bin/sh",
                &argv(&["-c", script]),
                None,
                SIZE,
                FONT,
                1,
                Duration::from_millis(0),
            );
            let got = match &result {
                Ok(launched) => launched.attempts.last().expect("an attempt").verdict,
                Err(LaunchError::Failed(attempts)) => {
                    attempts.last().expect("an attempt").verdict
                }
                Err(other) => panic!("{script:?} failed to even launch: {other:?}"),
            };
            assert_eq!(got, *want, "child {script:?}");
            if let Ok(mut launched) = result {
                launched.session.shutdown();
            }
        }
    }

    /// The retry loop, SEEN. Not "it eventually failed" - the attempts are counted, and the waits
    /// between them are required to have actually elapsed and to have doubled.
    ///
    /// This is the check the plan asks for by name, and it is the one that separates a retry loop
    /// from a comment claiming there is one: a loop that ran once and gave up produces exactly
    /// the same end result.
    #[test]
    fn a_failing_launch_retries_with_a_backoff_that_really_doubles() {
        let agent: &'static AgentDef = Box::leak(Box::new(fake(50)));
        let gpu = termisu_vt_render::GpuContext::new().expect("a GPU");
        let base = Duration::from_millis(40);

        let started = std::time::Instant::now();
        let error = into_pane(
            &gpu,
            agent,
            "/bin/sh",
            &argv(&["-c", "exit 1"]),
            None,
            SIZE,
            FONT,
            3,
            base,
        )
        .expect_err("a child that exits immediately cannot be Running");

        let LaunchError::Failed(attempts) = error else {
            panic!("wrong error for a failing child");
        };
        assert_eq!(attempts.len(), 3, "the retry loop did not run three times");
        assert_eq!(
            attempts.iter().map(|attempt| attempt.backoff).collect::<Vec<_>>(),
            vec![Duration::ZERO, base, base * 2],
            "the backoff did not double"
        );
        // The waits were real, not merely recorded. Without this the struct could be filled in
        // with the numbers the assertion above wants while nothing ever slept.
        assert!(
            started.elapsed() >= base * 3,
            "the whole run took {:?}, which is less than the backoffs it claims to have waited",
            started.elapsed()
        );
    }

    /// A retry loop must not paper over a REFUSAL. An approval bypass is the operator's decision
    /// to make, so it fails once and immediately - retrying it three times would be three
    /// chances for a race to let it through, and it would look like flakiness rather than policy.
    #[test]
    fn a_refused_argv_never_reaches_a_second_attempt() {
        let agent: &'static AgentDef = Box::leak(Box::new(fake(50)));
        let gpu = termisu_vt_render::GpuContext::new().expect("a GPU");

        let error = into_pane(
            &gpu,
            agent,
            "/bin/sh",
            &argv(&["--yolo"]),
            None,
            SIZE,
            FONT,
            3,
            Duration::from_millis(10),
        )
        .expect_err("a bypass must not launch");

        assert!(
            matches!(error, LaunchError::Refused(_)),
            "a bypass was retried instead of refused: {error:?}"
        );
    }

    /// A REAL agent CLI, in a real pane, verified from the typed grid.
    ///
    /// `#[ignore]`d deliberately: an automated suite must not start authenticated agent processes
    /// on the machine it runs on, every run, for as many agents as happen to be installed. This
    /// is run by hand when the launch path changes, and its result is recorded in the slice notes
    /// rather than assumed. Run it with:
    ///
    /// ```sh
    /// cargo test -p termisu --lib launch::tests::a_real_agent -- --ignored --nocapture
    /// ```
    #[test]
    #[ignore = "starts a real, authenticated agent CLI; run by hand"]
    fn a_real_agent_starts_and_is_seen_from_the_grid() {
        let mut probe = crate::agent::Probe::default();
        let claude = crate::agent::find("claude").expect("claude is in the registry");
        let Some(binary) = probe.resolve(claude) else {
            panic!("claude is not installed on this machine");
        };
        let gpu = termisu_vt_render::GpuContext::new().expect("a GPU");

        let mut launched = into_pane(
            &gpu,
            claude,
            &binary,
            &[],
            None,
            (1200, 700),
            FONT,
            3,
            Duration::from_millis(200),
        )
        .expect("the agent started");

        // The wedge, stated as an assertion: what the agent put on screen is READ, not scraped.
        let screen = launched.session.visible_text();
        println!(
            "attempts: {:?}\n--- grid ---\n{}\n--- end ---",
            launched.attempts, screen
        );
        assert_eq!(launched.attempts.last().expect("an attempt").verdict, Verdict::Running);
        assert!(
            !screen.trim().is_empty(),
            "the agent is running and the grid is empty, so the sensor is reading nothing"
        );
        launched.session.shutdown();
    }
}
