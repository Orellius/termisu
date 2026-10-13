//! A stable port block per workspace, so four agents in four worktrees do not fight over 3000.
//!
//! Git worktrees are the standard answer to running agents in parallel and the number that
//! keeps appearing is four to eight per developer. The isolation works for files and does
//! nothing for anything that is not a file: every dev server defaults to 3000, agent B dies
//! on `EADDRINUSE`, and agent B reports a broken build that is not broken. The formula
//! everyone hand-rolls is `PORT = BASE + INDEX * 10 + OFFSET`, plus a script that rewrites a
//! `.env` per tree, and it does not survive being moved to CI.
//!
//! Termisu can hand the BASE down, because it already owns the one place a child's
//! environment is set. What it must not do is hand down `PORT` itself: silently moving a
//! dev server off the port its operator typed is a bigger surprise than a variable nothing
//! reads yet, and the formula the ecosystem passes around wants a base anyway.
//!
//! **Stable, not sequential.** A base handed out in launch order moves every time the panes
//! open in a different order, which means a bookmark, a proxy rule and a database URL all
//! rot. It is derived from the workspace PATH, so the same worktree is the same block
//! forever and across machines.

use std::path::Path;

use termisu_vt_host::launch::{PORT_BLOCKS, PORT_LOW, PORT_SPAN, port_base};

#[test]
fn the_same_workspace_is_always_the_same_block() {
    let path = Path::new("/Users/someone/Projects/thing/.worktrees/feature-a");
    let first = port_base(path);
    for _ in 0..100 {
        assert_eq!(port_base(path), first, "the base moved between calls");
    }
    // A trailing slash is the same directory and must not be a different workspace.
    assert_eq!(
        port_base(Path::new(
            "/Users/someone/Projects/thing/.worktrees/feature-a/"
        )),
        first,
        "a trailing slash produced a different block"
    );
}

#[test]
fn different_workspaces_get_different_blocks() {
    // Sibling worktrees are the case that matters: they differ by one path component, which
    // is exactly where a weak hash collides.
    let bases: Vec<u16> = (0..64)
        .map(|index| {
            port_base(&Path::new("/Users/someone/Projects/thing/.worktrees").join(format!(
                "feature-{index}"
            )))
        })
        .collect();
    let distinct: std::collections::HashSet<u16> = bases.iter().copied().collect();
    // 64 draws from PORT_BLOCKS buckets. Perfect distinctness is not owed at that ratio, so
    // the assertion is that the hash SPREADS rather than that it never collides: a hash that
    // keys on the parent directory, or on length, would collapse all 64 onto one or two.
    assert!(
        distinct.len() >= 60,
        "64 sibling worktrees landed on only {} blocks out of {PORT_BLOCKS}; the measured \
         value with the shipped hash is 64 of 64, and 54 and 3 are what the two obvious \
         wrong ways of taking a bucket scored",
        distinct.len()
    );
}

#[test]
fn every_block_is_inside_the_declared_band() {
    for index in 0..500 {
        let base = port_base(&Path::new("/tmp/w").join(index.to_string()));
        assert!(
            base >= PORT_LOW,
            "{base} is below the band; it could land on a well-known port"
        );
        assert!(
            base + PORT_SPAN <= PORT_LOW + PORT_BLOCKS * PORT_SPAN,
            "{base} plus its span leaves the band"
        );
        // The whole block must stay clear of the ephemeral range macOS hands out to
        // outbound sockets, or a dev server binds a port the kernel is also giving away.
        assert!(
            base + PORT_SPAN < 49152,
            "{base} plus its span reaches the ephemeral range"
        );
        assert_eq!(
            (base - PORT_LOW) % PORT_SPAN,
            0,
            "{base} is not aligned to a block boundary"
        );
    }
}

#[test]
fn the_derivation_is_pinned_to_exact_values() {
    // A GOLDEN test, and it is the point of the whole file. Everything above stays green if
    // the hash is swapped for another good one -- and a base that moves between releases is
    // the exact failure this feature exists to prevent, because the operator's proxy rule
    // and database URL were written against the old one. Changing these numbers is allowed;
    // it just has to be a decision somebody makes on purpose.
    //
    // The paths are deliberately ones that CANNOT EXIST on any machine. `port_base`
    // canonicalizes when it can, so pinning a real path would pin a value that differs
    // between this machine and CI, and pinning `/tmp/a` would silently change the day
    // somebody creates it.
    assert_eq!(port_base(Path::new("/nonexistent-termisu-golden/one")), 32490);
    assert_eq!(port_base(Path::new("/nonexistent-termisu-golden/two")), 36940);
    assert_eq!(port_base(Path::new("/nonexistent-termisu-golden")), 30130);
}

#[test]
fn a_symlinked_workspace_is_the_same_workspace() {
    // On macOS `/tmp` IS a symlink to `/private/tmp`, so without resolution the same
    // worktree reached two ways is two workspaces with two port blocks. Nothing about that
    // is visible until an agent's server is suddenly on a port nothing is proxying.
    let root = std::env::temp_dir().join(format!(
        "termisu-portbase-{}",
        std::process::id()
    ));
    let real = root.join("real");
    let link = root.join("link");
    std::fs::create_dir_all(&real).expect("fixture");
    let _ = std::fs::remove_file(&link);
    std::os::unix::fs::symlink(&real, &link).expect("symlink");

    let through_link = port_base(&link);
    let direct = port_base(&real);
    let _ = std::fs::remove_dir_all(&root);

    assert_eq!(
        through_link, direct,
        "a worktree reached through a symlink got its own port block"
    );
}
