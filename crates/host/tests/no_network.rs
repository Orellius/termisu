//! Termisu makes no network connections, and this is the gate that keeps that true.
//!
//! The claim is written on the front of the README, so it stops being a mood and becomes
//! something the build can be wrong about. It is not enforceable by reading the code:
//! nobody writes `TcpStream::connect` in a terminal on purpose. What actually happens is
//! that some convenience crate arrives for an unrelated reason, drags an async runtime
//! and a TLS stack in behind it, and the claim is quietly false with no line of our own
//! code changed. So the gate reads the RESOLVED graph, not our sources.
//!
//! `Cargo.lock` is the right file to read even though it also covers dev-dependencies.
//! A test harness that can reach the network is still a thing in this repository that can
//! reach the network, and the difftest oracle in particular builds another project's
//! source: if that project ever grows a networked dependency, this should be a decision
//! somebody makes on purpose rather than a thing that happens.
//!
//! It lives in `crates/host` for the same reason `spawn_cwd.rs` does: the claim is about
//! the whole workspace, no crate owns it, and a gate has to run somewhere that runs.
//!
//! The OTHER half of the claim is the panel, which embeds WebKit and therefore embeds
//! something that can absolutely open a socket. That half cannot be gated from here. It is
//! gated by `--smoke-offline` in the Swift host, over `PanelNavigation`.

/// Crates that exist to move bytes over a wire, by name.
const NETWORK_CRATES: &[&str] = &[
    "reqwest", "hyper", "ureq", "curl", "isahc", "surf", "attohttpc", "tokio", "async-std",
    "smol", "mio", "socket2", "rustls", "native-tls", "openssl", "tungstenite", "quinn",
    "h2", "trust-dns-resolver", "hickory-resolver", "async-io", "polling",
];

/// Fragments that catch the NEXT one, which by definition is not on the list above.
///
/// A name list alone ages badly: it is a snapshot of what was popular the day it was
/// written, and the crate that eventually arrives will have a name nobody here has typed.
const NETWORK_FRAGMENTS: &[&str] = &[
    "http", "socket", "tls", "grpc", "websocket", "quic", "dns", "curl", "ssh2", "openssl",
];

/// False positives, each with the reason it is not a network crate.
///
/// Empty on purpose right now. Anything added here is a claim that a name LOOKS networked
/// and is not, and it needs to say why, because this is the only door in the gate.
const NOT_ACTUALLY_NETWORKED: &[(&str, &str)] = &[];

/// Every crate in a lock file that could open a socket, with the reason it was flagged.
///
/// A free function over the file's TEXT rather than a body inside the test, because the
/// test that reads the real lock can only ever go green: `cargo` REWRITES `Cargo.lock`
/// before running anything, so a package injected into it to prove the gate works is
/// silently removed again first. Measured that way on 2026-08-26, twice. The scanner has
/// to be exercised on a lock the toolchain does not own.
fn networked(lock: &str) -> Vec<String> {
    let excused: std::collections::HashMap<&str, &str> =
        NOT_ACTUALLY_NETWORKED.iter().copied().collect();
    let mut found = Vec::new();
    for line in lock.lines() {
        let Some(name) = line.strip_prefix("name = ") else {
            continue;
        };
        let name = name.trim().trim_matches('"');
        if excused.contains_key(name) {
            continue;
        }
        let lowered = name.to_ascii_lowercase();
        if NETWORK_CRATES.contains(&name) {
            found.push(format!("{name} (named)"));
        } else if let Some(fragment) = NETWORK_FRAGMENTS
            .iter()
            .find(|fragment| lowered.contains(**fragment))
        {
            found.push(format!("{name} (contains {fragment:?})"));
        }
    }
    found
}

fn crate_count(lock: &str) -> usize {
    lock.lines().filter(|l| l.starts_with("name = ")).count()
}

#[test]
fn nothing_in_the_resolved_graph_can_open_a_socket() {
    let lock = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../Cargo.lock"))
        .expect("Cargo.lock is at the workspace root");
    let count = crate_count(&lock);
    assert!(
        count > 50,
        "only {count} crates parsed out of Cargo.lock -- the format changed and this gate \
         went vacuous, which is worse than it failing"
    );

    let found = networked(&lock);
    assert!(
        found.is_empty(),
        "the README says Termisu makes no network connections, and the resolved graph now \
         holds: {}\n\nEither the dependency does not belong here, or it is a false positive \
         and belongs in NOT_ACTUALLY_NETWORKED with the reason written down.",
        found.join(", ")
    );
    println!("{count} crates resolved, none of them networked");
}

#[test]
fn the_scanner_finds_a_networked_crate_in_a_lock_it_is_given() {
    // THE CONTROL, and it is the whole reason the scanner is a function. Without it the
    // test above is a "nothing bad is present" assertion, which goes green just as happily
    // when the scanner is broken as when the graph is clean.
    let fixture = "\
[[package]]
name = \"termisu-vt-core\"
version = \"0.1.0\"

[[package]]
name = \"reqwest\"
version = \"0.12.0\"

[[package]]
name = \"blazing-http3-client\"
version = \"1.0.0\"

[[package]]
name = \"libc\"
version = \"0.2.0\"
";
    let found = networked(fixture);
    assert_eq!(
        found.len(),
        2,
        "the scanner found {found:?} in a lock holding exactly two networked crates"
    );
    assert!(found[0].starts_with("reqwest"), "the named list missed reqwest: {found:?}");
    assert!(
        found[1].starts_with("blazing-http3-client"),
        "the fragment list missed a crate nobody has heard of yet: {found:?}"
    );
    assert_eq!(crate_count(fixture), 4);
}

#[test]
fn the_gate_can_actually_see_a_networked_crate() {
    // The control. Without it, a typo in either list makes this file a green no-op forever,
    // which is exactly the failure mode a "nothing bad is present" assertion has.
    for candidate in ["reqwest", "tokio", "hyper-tls", "some-new-http-client", "quinn"] {
        let lowered = candidate.to_ascii_lowercase();
        let caught = NETWORK_CRATES.contains(&candidate)
            || NETWORK_FRAGMENTS.iter().any(|f| lowered.contains(f));
        assert!(caught, "{candidate} would slip past both lists");
    }
    // And it must not flag everything, or "no matches" means nothing.
    for innocent in ["termisu-vt-core", "swash", "windows-sys", "bitflags", "libc"] {
        let lowered = innocent.to_ascii_lowercase();
        let flagged = NETWORK_CRATES.contains(&innocent)
            || NETWORK_FRAGMENTS.iter().any(|f| lowered.contains(f));
        assert!(!flagged, "{innocent} was flagged as a network crate");
    }
}
