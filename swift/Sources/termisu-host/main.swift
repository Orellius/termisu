// The minimal Swift host, slice 8. Two modes:
//
//   termisu-host --smoke        headless: spawn a known child, poll until its pixels arrive,
//                             assert there is ink, exit 0/1. This is the CI-assertable
//                             proof that the ABI is consumable from Swift at all.
//   termisu-host [--command X]  a window: blit polled frames, forward keys, live resize.
//
// Everything the host knows arrives through CTermisuHost -- the five termisu_host_* calls.
// There is deliberately no second channel into the Rust side.

import WebKit
import AppKit
import Combine
import CTermisuHost

/// Runs `body` with a borrowed C string, or with NULL when there is nothing to lend.
///
/// `withCString` has no optional form, and the alternative -- a branch per optional
/// argument -- doubles with each one. Two of them would already be four spawn sites
/// that have to stay in step.
///
/// Module-wide rather than private since the agent spawn in `Agents.swift` is a third site.
/// A second copy of a borrow helper is a second chance to get a lifetime wrong.
func withOptionalCString<R>(
    _ value: String?, _ body: (UnsafePointer<CChar>?) -> R
) -> R {
    guard let value else { return body(nil) }
    return value.withCString { body($0) }
}

func spawnHost(
    cols: UInt16, rows: UInt16, fontSize: Float, command: String?, autoDirection: Bool = false,
    config: OpaquePointer? = nil, cwd: String? = nil
) -> OpaquePointer? {
    var host: OpaquePointer?
    let result = withOptionalCString(command) { commandPointer in
        withOptionalCString(cwd) { cwdPointer in
            var options = TermisuHostOptions(
                cols: cols, rows: rows, font_size: fontSize, command: commandPointer,
                auto_direction: autoDirection, config: config, cwd: cwdPointer)
            return termisu_host_spawn(&options, &host)
        }
    }
    guard result == TERMISU_HOST_SUCCESS, let host else {
        FileHandle.standardError.write(Data("spawn failed: \(result)\n".utf8))
        return nil
    }
    return host
}

/// Headless proof: a child's output becomes ink, through the archive, from Swift.
func runSmoke() -> Int32 {
    guard let host = spawnHost(
        cols: 80, rows: 24, fontSize: 0, command: "printf 'TERMISU-VT-SMOKE\\n'")
    else { return 1 }
    defer { termisu_host_free(host) }

    let deadline = Date().addingTimeInterval(10)
    var frame = TermisuHostFrame()
    while Date() < deadline {
        guard termisu_host_poll(host, &frame) == TERMISU_HOST_SUCCESS else {
            FileHandle.standardError.write(Data("poll failed\n".utf8))
            return 1
        }
        if frame.child_exited, let pixels = frame.pixels, !frame.drew {
            // The child is gone and its final frame is drawn. Ink = any pixel that is not
            // the background, and the background is whatever the top-left corner shows.
            let count = Int(frame.width) * Int(frame.height)
            var ink = 0
            for index in 0..<count {
                let pixel = pixels.advanced(by: index * 4)
                if pixel[0] != pixels[0] || pixel[1] != pixels[1] || pixel[2] != pixels[2] {
                    ink += 1
                }
            }
            guard ink > 0 else {
                FileHandle.standardError.write(Data("frame arrived with no ink\n".utf8))
                return 1
            }
            print("SMOKE OK: \(ink) ink pixels in \(frame.width)x\(frame.height), generation \(frame.generation)")
            return 0
        }
        usleep(10_000)
    }
    FileHandle.standardError.write(Data("no settled frame within 10s\n".utf8))
    return 1
}

/// Headless proof of the cwd-keyed ghost, end to end through the Swift seam.
///
/// This is the seam PR #15 shipped untested, and its failure is SILENT: if the OSC 7
/// event never reaches the session, `pwdRaw` stays empty, every lookup falls back to
/// global history, and the result is indistinguishable from the feature not existing.
/// So the assertion is the discriminating one -- a command run HERE must win over a
/// NEWER command run elsewhere. With the cwd lost, the newer one wins and this fails.
func runHistorySmoke() -> Int32 {
    let directoryA = "/tmp/termisu-cwd-smoke-a"
    let directoryB = "/tmp/termisu-cwd-smoke-b"

    /// Spawns a child whose only job is to report a directory, and returns the session
    /// once that report has been drained. Real OSC 7 bytes down a real pty -- the point
    /// is to exercise the event path, not to assign to `pwdRaw` directly.
    func sessionReporting(_ directory: String) -> Session? {
        guard let session = Session(
            command: "printf '\\033]7;file://localhost\(directory)\\033\\\\'",
            cols: 80, rows: 24, fontSize: 0, autoDirection: false, title: "cwd-smoke")
        else { return nil }

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            _ = session.poll()
            for event in session.drainEvents() {
                if case .pwd = event { return session }
            }
            if session.exited, !session.pwdRaw.isEmpty { return session }
            usleep(10_000)
        }
        FileHandle.standardError.write(
            Data("no OSC 7 event for \(directory) within 10s\n".utf8))
        return nil
    }

    let storePath = "/tmp/termisu-cwd-smoke-history"
    try? FileManager.default.removeItem(atPath: storePath)
    var store: OpaquePointer?
    guard storePath.withCString({ termisu_history_load($0, &store) }) == TERMISU_HOST_SUCCESS
    else {
        FileHandle.standardError.write(Data("history store failed to load\n".utf8))
        return 1
    }

    guard let inA = sessionReporting(directoryA) else { return 1 }
    guard String(decoding: inA.pwdRaw, as: UTF8.self).contains(directoryA) else {
        FileHandle.standardError.write(
            Data(("session reported \(String(decoding: inA.pwdRaw, as: UTF8.self)),"
                + " expected \(directoryA)\n").utf8))
        return 1
    }
    inA.recordCommand(store, command: "echo alpha-here")

    guard let inB = sessionReporting(directoryB) else { return 1 }
    inB.recordCommand(store, command: "echo beta-here")

    // Back where alpha ran. beta is NEWER, so a lookup that lost the directory returns it.
    guard let backInA = sessionReporting(directoryA) else { return 1 }
    let suggestion = backInA.suggestion(store, for: "echo ")

    guard suggestion == "echo alpha-here" else {
        FileHandle.standardError.write(
            Data("""
                cwd-keyed history FAILED: suggested \(suggestion ?? "nothing"), \
                expected 'echo alpha-here'. The session's reported directory was \
                '\(String(decoding: backInA.pwdRaw, as: UTF8.self))' -- if that is empty, \
                the OSC 7 event never reached the Swift layer and every lookup is global.

                """.utf8))
        return 1
    }

    // The control: with no directory, the newest match anywhere is the right answer.
    // Without this, the assertion above would also pass on a store holding only alpha.
    guard let globalSession = Session(
        command: "true", cols: 80, rows: 24, fontSize: 0, autoDirection: false,
        title: "cwd-smoke-control"), globalSession.pwdRaw.isEmpty,
        globalSession.suggestion(store, for: "echo ") == "echo beta-here"
    else {
        FileHandle.standardError.write(
            Data("control failed: a session with no cwd must fall back to the newest\n".utf8))
        return 1
    }

    print("HISTORY SMOKE OK: in \(directoryA) the ghost suggests 'echo alpha-here'; "
        + "with no cwd it suggests the newer 'echo beta-here'")
    return 0
}

/// Headless proof of the web-panel bridge, both directions, with no window.
///
/// The seam this asserts is the one that fails SILENTLY (SCAR-004): WKWebView does not
/// throw when a script message handler was never registered, and evaluateJavaScript
/// against a document whose receiver is missing reports a JS exception nobody reads. So
/// a panel that is completely disconnected looks exactly like a panel that is working
/// and simply has nothing to show. The probe is therefore a ROUND TRIP with a nonce: the
/// host posts `ping`, the panel's bridge module answers `pong` with the same nonce, and
/// only receiving that nonce back proves both directions of the channel carried data.
///
/// Run against a built `web/dist` via `--web-dir`, since the bare CLI binary has no
/// resource bundle. The control is `--smoke-panel-control`, which loads a document with
/// the bridge stripped out and must NOT get its nonce back.
func runPanelSmoke(webDir: String?, control: Bool) -> Int32 {
    guard var url = WebPanel.documentURL(override: webDir) else {
        FileHandle.standardError.write(
            Data("panel document not found; build web/ or pass --web-dir\n".utf8))
        return 1
    }

    // The control's document is the real one with the host's entry point removed --
    // the single line that makes the bridge exist. Everything else about the load,
    // the handler registration and the probe is identical, so a pass here would mean
    // the assertion is not measuring the bridge at all.
    if control {
        guard let html = try? String(contentsOf: url, encoding: .utf8) else {
            FileHandle.standardError.write(Data("could not read the panel document\n".utf8))
            return 1
        }
        let broken = html.replacingOccurrences(
            of: "window.__termisuReceive=", with: "window.__termisuDisconnected=")
        guard broken != html else {
            FileHandle.standardError.write(
                Data("control could not find the receiver to remove; the bundle changed shape\n".utf8))
            return 1
        }
        let path = NSTemporaryDirectory() + "termisu-panel-control.html"
        guard (try? broken.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
            FileHandle.standardError.write(Data("could not write the control document\n".utf8))
            return 1
        }
        url = URL(fileURLWithPath: path)
    }

    guard let panel = WebPanel(documentURL: url) else {
        FileHandle.standardError.write(Data("panel could not be constructed\n".utf8))
        return 1
    }
    // Off-screen but in a real window: WKWebView does not run a document that is in no
    // window at all, and this must exercise the same path the app uses.
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled], backing: .buffered, defer: false)
    panel.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    window.contentView?.addSubview(panel)

    // Before anything: the document cannot be on screen yet, and that is the assertion
    // that keeps WebKit's white pre-paint off a dark terminal. A panel that revealed its
    // web view at construction flashes white across its whole area while WebKit starts
    // up -- obvious on the first open, brief once the web process is warm, and always
    // drawn (operator-reported, 2026-08-02).
    guard !panel.isContentVisible else {
        FileHandle.standardError.write(
            Data("PANEL SMOKE FAILED: the web view was visible before the document was\n".utf8))
        return 1
    }

    let nonce = UUID().uuidString
    var pongedWith: String?
    var ready = false
    var errors: [String] = []
    panel.onProtocolError = { errors.append($0) }
    panel.onMessage = { message in
        switch message {
        case .ready: ready = true
        case .pong(let echoed): pongedWith = echoed
        default: break
        }
    }
    panel.post(.ping(nonce: nonce))

    // Waits for BOTH signals. `ready` comes from the React layer once it has mounted and
    // `pong` from the bridge module, so requiring both means the document is proven to
    // have executed AND the channel is proven to carry data. Waiting only for the pong
    // would pass against a bundle whose UI never rendered at all.
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline, pongedWith == nil || !ready {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }

    if control {
        // The control is only worth something if it fails for the RIGHT reason. Removing
        // the receiver does not stop React mounting, so a correct control still reports
        // `ready` -- and demanding that here is what distinguishes "the bridge is dead"
        // from "the document never loaded", which is how this control passed VACUOUSLY
        // on its first run (a navigation-policy bug refused the document outright, and
        // the missing nonce proved nothing at all).
        guard ready else {
            FileHandle.standardError.write(
                Data("""
                    CONTROL INVALID: the document never reported ready, so a missing nonce \
                    says nothing about the bridge. errors=\
                    \(errors.isEmpty ? "none" : errors.joined(separator: "; "))

                    """.utf8))
            return 1
        }
        guard pongedWith == nil else {
            FileHandle.standardError.write(
                Data("CONTROL FAILED: a document with no receiver still answered the probe\n".utf8))
            return 1
        }
        print(
            "PANEL CONTROL OK: the document loaded and reported ready, and with the "
                + "receiver removed the nonce never came back")
        return 0
    }

    guard let pongedWith else {
        FileHandle.standardError.write(
            Data("""
                PANEL SMOKE FAILED: no pong within 15s. ready=\(ready), \
                errors=\(errors.isEmpty ? "none" : errors.joined(separator: "; "))

                """.utf8))
        return 1
    }
    guard pongedWith == nonce else {
        FileHandle.standardError.write(
            Data("PANEL SMOKE FAILED: echoed \(pongedWith), sent \(nonce)\n".utf8))
        return 1
    }
    guard ready else {
        FileHandle.standardError.write(
            Data("PANEL SMOKE FAILED: the panel answered the probe but never mounted\n".utf8))
        return 1
    }
    guard panel.isContentVisible else {
        FileHandle.standardError.write(
            Data("PANEL SMOKE FAILED: the document reported ready but stayed hidden\n".utf8))
        return 1
    }
    guard errors.isEmpty else {
        FileHandle.standardError.write(
            Data("PANEL SMOKE FAILED: bridge errors: \(errors.joined(separator: "; "))\n".utf8))
        return 1
    }
    print(
        "PANEL SMOKE OK: hidden until ready, then shown; the panel mounted and nonce "
            + "\(nonce) crossed to it and back")
    return 0
}

/// `--smoke-files`: what the file panel may read, as a truth table over a real fixture.
///
/// The panel sends paths, and a path from the document is untrusted input that names a
/// file on this disk. Every way out of the root is tried here (`..`, an absolute path, a
/// NUL, a symlink that points outside) next to the ways that must still work (a symlink
/// that stays inside, a root reached through a symlink), because a boundary that refuses
/// everything passes every "refused" assertion and is still broken.
func runFilesSmoke() -> Int32 {
    func fail(_ why: String) -> Int32 {
        FileHandle.standardError.write(Data("files smoke: \(why)\n".utf8))
        return 1
    }
    let base = NSTemporaryDirectory() + "termisu-files-smoke-\(getpid())"
    let root = base + "/root"
    let manager = FileManager.default
    try? manager.removeItem(atPath: base)
    defer { try? manager.removeItem(atPath: base) }
    let mainText = "fn main() {\n    println!(\"hi\");\n}\n"
    do {
        for directory in ["src", "zdir", "target", "טיוטות", ".git-not-hidden"] {
            try manager.createDirectory(
                atPath: root + "/" + directory, withIntermediateDirectories: true)
        }
        try manager.createDirectory(atPath: base + "/outside", withIntermediateDirectories: true)
        // Shares the root's name as a PREFIX: a boundary check without the trailing "/"
        // would take it for the inside.
        try manager.createDirectory(atPath: base + "/root-sibling", withIntermediateDirectories: true)
        try "sibling\n".write(toFile: base + "/root-sibling/x.txt", atomically: true, encoding: .utf8)
        try mainText.write(toFile: root + "/src/main.rs", atomically: true, encoding: .utf8)
        try "# Readme\n".write(toFile: root + "/README.md", atomically: true, encoding: .utf8)
        try "target\nטיוטות\n".write(toFile: root + "/.gitignore", atomically: true, encoding: .utf8)
        try "secret\n".write(toFile: base + "/outside/secret.txt", atomically: true, encoding: .utf8)
        try Data([0x61, 0x00, 0x62]).write(to: URL(fileURLWithPath: root + "/a.bin"))
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0A]).write(to: URL(fileURLWithPath: root + "/latin1.txt"))
        try Data(repeating: 0x61, count: FileAccess.readLimit + 1)
            .write(to: URL(fileURLWithPath: root + "/big.txt"))
        try manager.createSymbolicLink(atPath: root + "/link-out", withDestinationPath: base + "/outside")
        try manager.createSymbolicLink(atPath: root + "/link-in", withDestinationPath: root + "/src")
        try manager.createSymbolicLink(atPath: base + "/root-link", withDestinationPath: root)
    } catch {
        return fail("could not build the fixture: \(error)")
    }
    guard Git.run(["init", "-q"], in: root).status == 0 else {
        return fail("git init failed in the fixture")
    }

    func refused(_ outcome: Result<String, PanelFailure>) -> String? {
        if case .failure(let reason) = outcome { return reason.description }
        return nil
    }

    // Ways out, each of which must be refused.
    for escape in ["../outside/secret.txt", "src/../../outside/secret.txt", "/etc/hosts",
        "link-out/secret.txt", "src/main.rs\u{0}", "../root-sibling/x.txt"]
    {
        guard refused(FileAccess.read(root: root, relative: escape)) != nil else {
            return fail("read '\(escape)' was allowed; it leaves the root")
        }
    }
    if case .success = FileAccess.list(root: root, relative: "link-out") {
        return fail("listing link-out was allowed; it points outside the root")
    }

    // Ways in, each of which must work.
    guard case .success(let viaLink) = FileAccess.read(root: root, relative: "link-in/main.rs"),
        viaLink == mainText
    else {
        return fail("a symlink that stays inside the root was refused")
    }
    guard case .success(let viaRootLink) = FileAccess.read(
        root: base + "/root-link", relative: "src/main.rs"), viaRootLink == mainText
    else {
        return fail("a root reached through a symlink refused its own files")
    }

    // What is not shown, and why.
    let reasons: [(String, String)] = [
        ("a.bin", "binary"), ("latin1.txt", "not UTF-8"), ("big.txt", "too large"),
        ("zdir", "not a regular file"), ("missing.txt", "cannot open"),
    ]
    for (path, expected) in reasons {
        guard let reason = refused(FileAccess.read(root: root, relative: path)),
            reason.contains(expected)
        else {
            return fail("\(path) should be refused as '\(expected)'")
        }
    }

    // The listing: `.git` hidden, directories first, git's ignores marked.
    let listing: [FileAccess.Entry]
    switch FileAccess.list(root: root, relative: "", ignoredNames: Git.ignoredNames) {
    case .success(let result): listing = result.entries
    case .failure(let reason): return fail("listing the root failed: \(reason)")
    }
    let names = listing.map(\.name)
    guard !names.contains(".git"), names.contains(".git-not-hidden") else {
        return fail("`.git` must be hidden and only `.git`: \(names)")
    }
    guard let lastDirectory = listing.lastIndex(where: \.isDirectory),
        let firstFile = listing.firstIndex(where: { !$0.isDirectory }), lastDirectory < firstFile
    else {
        return fail("directories must come first: \(names)")
    }
    guard listing.first(where: { $0.name == "target" })?.ignored == true,
        listing.first(where: { $0.name == "טיוטות" })?.ignored == true,
        listing.first(where: { $0.name == "src" })?.ignored == false
    else {
        return fail("git's ignores are not marked: \(listing.filter(\.ignored).map(\.name))")
    }

    print(
        "FILES SMOKE OK: 6 ways out refused and a listing through link-out refused; a "
            + "symlink inside and a root behind a symlink both read; binary, non-UTF-8, "
            + "over 2 MB, a directory and a missing file each refused with their reason; "
            + "the listing hides .git, puts directories first and marks target/ and a Hebrew-named "
            + "directory ignored")
    return 0
}

/// Headless proof of the file panel, bridge to grammar, with no window shown.
///
/// Plays AppDelegate's half against the real document and a fixture root: answers
/// `listDirectory` and `openFile` through `FileAccess`, then asks the panel to open a
/// Rust file and a Markdown file. The panel reports `viewerState` for each, and that is
/// the evidence: the language it chose, how many lines a grammar coloured (tokenize,
/// which needs no frame; a never-shown window gets no requestAnimationFrame, measured in
/// P0) and whether a blob worker could start.
///
/// The control strips `worker-src blob:` and `font-src data:` from the document's CSP and
/// must see the worker and the icon font reported blocked while the file still opens, so
/// the gate is shown to measure the two CSP lines the maintainer approved rather than something
/// that is always "ok".
func runFilePanelSmoke(webDir: String?, control: Bool) -> Int32 {
    func fail(_ why: String) -> Int32 {
        FileHandle.standardError.write(
            Data("FILE PANEL \(control ? "CONTROL" : "SMOKE") FAILED: \(why)\n".utf8))
        return 1
    }
    guard var url = WebPanel.documentURL(override: webDir) else {
        return fail("panel document not found; build web/ or pass --web-dir")
    }
    if control {
        guard let html = try? String(contentsOf: url, encoding: .utf8) else {
            return fail("could not read the panel document")
        }
        let broken = html
            .replacingOccurrences(of: "worker-src blob:; ", with: "")
            .replacingOccurrences(of: "font-src data:; ", with: "")
        guard broken.count == html.count - "worker-src blob:; font-src data:; ".count else {
            return fail("control could not find both CSP lines to remove; the CSP changed shape")
        }
        let path = NSTemporaryDirectory() + "termisu-file-panel-control.html"
        guard (try? broken.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
            return fail("could not write the control document")
        }
        url = URL(fileURLWithPath: path)
    }

    let root = NSTemporaryDirectory() + "termisu-file-panel-smoke-\(getpid())"
    let manager = FileManager.default
    try? manager.removeItem(atPath: root)
    defer { try? manager.removeItem(atPath: root) }
    let rust = """
        use std::io;

        /// Reads a line and echoes it.
        fn main() -> io::Result<()> {
            let mut line = String::new();
            io::stdin().read_line(&mut line)?;
            println!("{}", line.trim());
            Ok(())
        }

        """
    let markdown = """
        # Fixture

        A paragraph with **bold**, `code` and a [link](src/main.rs).

        - one
        - two

        """
    do {
        try manager.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        try rust.write(toFile: root + "/src/main.rs", atomically: true, encoding: .utf8)
        try markdown.write(toFile: root + "/README.md", atomically: true, encoding: .utf8)
    } catch {
        return fail("could not build the fixture: \(error)")
    }

    guard let panel = WebPanel(documentURL: url) else {
        return fail("panel could not be constructed")
    }
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
        styleMask: [.titled], backing: .buffered, defer: false)
    panel.frame = NSRect(x: 0, y: 0, width: 1080, height: 700)
    window.contentView?.addSubview(panel)

    let theme = PanelTheme(
        background: "#1e1e24", foreground: "#e6e6e6", accent: "#7aa2f7", dim: "#8b8b96")
    var ready = false
    var errors: [String] = []
    var opened: [String] = []
    var states: [String: ViewerState] = [:]
    panel.onProtocolError = { errors.append($0) }
    panel.onMessage = { message in
        switch message {
        case .ready:
            ready = true
            panel.post(.initialize(theme: theme, panel: .files))
            panel.post(.tree(root: root, error: nil))
            if case .success(let listing) = FileAccess.list(root: root, relative: "") {
                panel.post(.directory(path: "", entries: listing.entries, error: nil))
            }
            panel.post(.select(path: "src/main.rs", line: 7))
        case .listDirectory(let path):
            if case .success(let listing) = FileAccess.list(root: root, relative: path) {
                panel.post(.directory(path: path, entries: listing.entries, error: nil))
            }
        case .openFile(let path):
            opened.append(path)
            switch FileAccess.read(root: root, relative: path) {
            case .success(let text): panel.post(.fileContent(path: path, text: text, error: nil))
            case .failure(let reason):
                panel.post(.fileContent(path: path, text: "", error: reason.description))
            }
        case .viewerState(let state):
            states[state.path] = state
        case .decodeError(let detail):
            errors.append("decodeError: \(detail)")
        default:
            break
        }
    }

    func wait(for path: String) -> ViewerState? {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, states[path] == nil {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return states[path]
    }
    func describe(_ state: ViewerState?) -> String {
        guard let state else { return "no viewerState" }
        return "\(state.language), \(state.lines) lines, \(state.tokenizedLines) coloured, "
            + "worker \(state.worker), icons \(state.icons)"
    }
    let status = { "ready=\(ready) opened=\(opened) errors=\(errors.isEmpty ? "none" : errors.joined(separator: "; "))" }

    guard let code = wait(for: "src/main.rs") else {
        return fail("no viewerState for src/main.rs within 20s. \(status())")
    }
    panel.post(.select(path: "README.md", line: nil))
    guard let readme = wait(for: "README.md") else {
        return fail("no viewerState for README.md within 20s. \(status())")
    }
    let lines = { (text: String) in text.components(separatedBy: "\n").count }

    if control {
        guard code.worker == "blocked", readme.worker == "blocked" else {
            return fail("with `worker-src blob:` removed the worker still reported \(code.worker)")
        }
        guard code.icons == "blocked" else {
            return fail("with `font-src data:` removed the icon font still reported \(code.icons)")
        }
        guard code.language == "rust", code.tokenizedLines > 0 else {
            return fail("the control must still open and colour the file: \(describe(code))")
        }
        print(
            "FILE PANEL CONTROL OK: with `worker-src blob:` and `font-src data:` stripped from "
                + "the CSP the worker and the icon font report blocked, while src/main.rs still "
                + "opened (\(describe(code)))")
        return 0
    }

    guard opened == ["src/main.rs", "README.md"] else {
        return fail("the panel should have asked for exactly the two files, asked for \(opened)")
    }
    guard code.language == "rust", code.lines == lines(rust), code.tokenizedLines > 0,
        code.worker == "ok", code.icons == "ok"
    else {
        return fail("src/main.rs: \(describe(code)); expected rust, \(lines(rust)) lines, "
            + "some coloured, worker ok, icons ok")
    }
    // P2: the host asked for line 7, the way a cmd+clicked `src/main.rs:7` does, and the
    // editor reports where it actually is. The README was opened with no line.
    guard code.line == 7, readme.line == nil else {
        return fail("the editor is on line \(code.line.map(String.init) ?? "none") of src/main.rs "
            + "and \(readme.line.map(String.init) ?? "none") of README.md; expected 7 and none")
    }
    guard readme.language == "markdown", readme.lines == lines(markdown),
        readme.tokenizedLines > 0, readme.worker == "ok"
    else {
        return fail("README.md: \(describe(readme)); expected markdown, \(lines(markdown)) lines, "
            + "some coloured, worker ok")
    }
    guard errors.isEmpty else {
        return fail("bridge errors: \(errors.joined(separator: "; "))")
    }
    print(
        "FILE PANEL SMOKE OK: the host's select opened src/main.rs (\(describe(code))) "
            + "and README.md (\(describe(readme))), each read through FileAccess, no bridge errors; "
            + "src/main.rs was asked for at line 7 and the editor is on line 7")
    return 0
}

/// Headless proof of the workspace layer (S5), against a real repository.
///
/// The assertion that carries the weight is the REFUSAL. `Worktrees.remove` never passes
/// --force, so git declines to delete a worktree with uncommitted changes, and that is
/// the one behaviour standing between this feature and destroying an agent's unpushed
/// work. A remove that quietly succeeded on a dirty tree would look identical to a
/// correct one from the outside: the session closes, the tab disappears, and the loss is
/// discovered later. So the test dirties the tree, requires the removal to FAIL and the
/// directory to survive, then cleans it and requires the same call to succeed.
func runWorktreeSmoke() -> Int32 {
    let base = NSTemporaryDirectory() + "termisu-worktree-smoke-\(ProcessInfo.processInfo.processIdentifier)"
    let root = base + "/repo"
    try? FileManager.default.removeItem(atPath: base)
    defer { try? FileManager.default.removeItem(atPath: base) }

    func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("WORKTREE SMOKE FAILED: \(message)\n".utf8))
        return 1
    }

    do {
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
    } catch {
        return fail("could not create \(root): \(error)")
    }
    // A repository with one commit: `git worktree add` has nothing to point at otherwise.
    for arguments in [
        ["init", "--initial-branch=main"],
        ["config", "user.email", "smoke@termisu.local"],
        ["config", "user.name", "termisu smoke"],
    ] {
        let result = Git.run(arguments, in: root)
        guard result.status == 0 else { return fail("git \(arguments[0]): \(result.err)") }
    }
    guard (try? "seed\n".write(toFile: root + "/seed.txt", atomically: true, encoding: .utf8))
        != nil
    else { return fail("could not seed the repository") }
    for arguments in [["add", "-A"], ["commit", "-m", "seed"]] {
        let result = Git.run(arguments, in: root)
        guard result.status == 0 else { return fail("git \(arguments[0]): \(result.err)") }
    }

    // Create.
    let branch = "smoke-workspace"
    guard case .success(let worktree) = Worktrees.add(root: root, branch: branch) else {
        return fail("worktree add did not succeed")
    }
    guard FileManager.default.fileExists(atPath: worktree.path) else {
        return fail("worktree add reported success but \(worktree.path) does not exist")
    }
    // The sibling convention, asserted rather than assumed: a worktree nested inside its
    // own parent's tree pollutes that parent's status forever.
    guard !worktree.path.hasPrefix(root + "/") else {
        return fail("the worktree landed INSIDE the repository: \(worktree.path)")
    }

    // List, through the real porcelain parser.
    guard case .success(let trees) = Worktrees.list(containing: root) else {
        return fail("worktree list did not succeed")
    }
    guard trees.first?.isPrimary == true else {
        return fail("the first record must be the primary work tree")
    }
    guard let listed = trees.first(where: { $0.branch == branch }) else {
        return fail("the new worktree is missing from the list: \(trees.map(\.label))")
    }
    guard !listed.isPrimary else { return fail("a secondary worktree was marked primary") }

    // The refusal. This is the assertion the whole file exists for.
    guard (try? "unsaved\n".write(
        toFile: listed.path + "/work-in-progress.txt", atomically: true, encoding: .utf8)) != nil
    else { return fail("could not dirty the worktree") }
    let refused = Worktrees.remove(root: root, worktree: listed)
    guard case .failure(let refusal) = refused else {
        return fail(
            "A DIRTY WORKTREE WAS REMOVED. This is the case that destroys unpushed work; "
                + "remove() must never pass --force.")
    }
    guard FileManager.default.fileExists(atPath: listed.path) else {
        return fail("removal reported failure but the directory is gone anyway")
    }

    // And the other direction, so the refusal above is not simply "remove never works".
    try? FileManager.default.removeItem(atPath: listed.path + "/work-in-progress.txt")
    guard case .success = Worktrees.remove(root: root, worktree: listed) else {
        return fail("a clean worktree could not be removed either, so the refusal proves nothing")
    }
    guard !FileManager.default.fileExists(atPath: listed.path) else {
        return fail("removal reported success but the directory survives")
    }

    // The primary is never removable, whatever the caller asks.
    guard case .failure = Worktrees.remove(root: root, worktree: trees[0]) else {
        return fail("the primary work tree was removed")
    }

    print(
        "WORKTREE SMOKE OK: created \(listed.path), removal REFUSED while dirty "
            + "(\(refusal.description.split(separator: "\n").first ?? "")), succeeded once clean")
    return 0
}


/// Headless proof that an agent really reaches a pane THROUGH THE SWIFT SEAM, and that the
/// approval guard survives the trip.
///
/// The Rust side is gated in `crates/host/tests/agent_abi.rs`. This is the half that suite
/// cannot see: `Agent.all`, the argv borrow, `Session.agent`, and the failure classification
/// the UI shows. Every one of those can be wrong while the C surface underneath is perfect,
/// and the way they would be wrong is silent - a dangling argv pointer, a `Result` mapped to
/// the wrong case, a menu that lists nothing.
///
/// A FAKE agent on PATH, not a real one: an automated gate must not start authenticated agent
/// processes on somebody's machine every time it builds. `opencode` is a real registry entry,
/// and our directory goes first on PATH so this behaves identically on a machine that has the
/// real one installed.
func runAgentSmoke() -> Int32 {
    func fail(_ why: String) -> Int32 {
        FileHandle.standardError.write(Data("agent smoke: \(why)\n".utf8))
        return 1
    }

    let directory = "/tmp/termisu-agent-smoke-\(getpid())"
    let binary = "\(directory)/opencode"
    try? FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: true)
    guard
        FileManager.default.createFile(
            atPath: binary,
            contents: Data("#!/bin/sh\nprintf 'AGENT-SMOKE-UP\\n'\nexec cat\n".utf8),
            attributes: [.posixPermissions: 0o755])
    else { return fail("could not write the fake agent at \(binary)") }
    defer { try? FileManager.default.removeItem(atPath: directory) }
    setenv("PATH", "\(directory):\(ProcessInfo.processInfo.environment["PATH"] ?? "")", 1)

    // The registry, as a menu would read it.
    let agents = Agent.all()
    guard !agents.isEmpty else { return fail("the registry came back empty") }
    guard let opencode = agents.first(where: { $0.id == "opencode" }) else {
        return fail("opencode is not in the registry")
    }
    guard opencode.path == binary else {
        return fail("resolved \(opencode.path ?? "nothing"), expected our fake at \(binary)")
    }
    guard agents.contains(where: { $0.typeAfterLaunch }),
        agents.contains(where: { !$0.typeAfterLaunch })
    else { return fail("both prompt strategies did not survive the trip into Swift") }

    // THE CONTROL, FIRST. A bypass must be refused rather than stripped, and it must be
    // refused with the FLAG NAMED - a Swift layer that mapped every failure onto one case
    // would still "work" and would tell the operator nothing.
    switch Session.agent(
        opencode, argv: ["--yolo"], cols: 80, rows: 24, fontSize: 0, autoDirection: false)
    {
    case .success: return fail("a --yolo launch was allowed through the Swift seam")
    case .failure(.refused(let flag, let at)):
        guard flag == "--yolo", at == 0 else {
            return fail("refused, but named \(flag) at \(at)")
        }
    case .failure(let other): return fail("refused for the wrong reason: \(other.summary)")
    }

    // And the launch itself, with the operator's own near-miss flag riding along - so the
    // refusal above is about the FLAG and not about this path being broken.
    let launched = Session.agent(
        opencode, argv: ["--autosave"], cols: 80, rows: 24, fontSize: 0, autoDirection: false)
    guard case .success(let session) = launched else {
        guard case .failure(let why) = launched else { return fail("unreachable") }
        return fail("the agent did not launch: \(why.summary)")
    }
    defer { session.close() }

    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        _ = session.poll()
        // Read off the TYPED GRID, never off the byte stream: that is the whole wedge, and a
        // byte-scraping version of this could be fooled by an agent that repaints its banner.
        if (0..<24).contains(where: { session.rowText(UInt16($0), semantic: UInt8(TERMISU_TEXT_ALL)).contains("AGENT-SMOKE-UP") }) {
            print(
                "AGENT SMOKE OK: \(agents.count) agents listed, --yolo refused by name, "
                    + "\(opencode.name) up in a pane from \(binary)")
            return 0
        }
        usleep(10_000)
    }
    return fail("the agent never appeared on the grid within 15s")
}

/// Chrome geometry, colours, state marks and the tab chords.
///
/// Pure arithmetic and values, no window. The layout half used to assert that the pane and
/// the docked sidebar TILED the content; the sidebar went on 2026-10-02 (the maintainer: tabs, no
/// sidebars), so what is left to assert is the band. It must hold the top `topInset` points
/// exactly, the pane must start where it ends, and both must survive a window shorter than
/// the band itself, which is where a subtraction goes negative and nobody looks.
func runChromeSmoke() -> Int32 {
    func fail(_ why: String) -> Int32 {
        FileHandle.standardError.write(Data("chrome smoke: \(why)\n".utf8))
        return 1
    }

    let inset = ChromeLayout.topInset
    let widths: [CGFloat] = [1120, 800, 300, 100, 0]
    let heights: [CGFloat] = [700, 200, inset, 10, 0]
    for width in widths {
        for height in heights {
            let layout = ChromeLayout.compute(content: NSSize(width: width, height: height))
            let (pane, band) = (layout.pane, layout.band)
            let at = "at \(width)x\(height)"
            if pane.minX != 0 || pane.width != width || band.minX != 0 || band.width != width {
                return fail("pane \(pane) and band \(band) do not both span the full width \(at)")
            }
            // Stacked, with no gap and no overlap: the pane runs from the floor to where the
            // band starts, and the band runs from there to the top.
            if pane.minY != 0 || pane.maxY != band.minY || band.maxY != height {
                return fail("pane \(pane) and band \(band) do not stack exactly \(at)")
            }
            if band.height != min(inset, height) || pane.height < 0 {
                return fail("band \(band.height)pt, pane \(pane.height)pt \(at)")
            }
        }
    }
    // THE CONTROL. The inset is the only thing standing between the band's glass and the
    // grid's first row, and an inset dropped to zero passes every stacking assertion above.
    let big = ChromeLayout.compute(content: NSSize(width: 1120, height: 700))
    if inset < 52 || big.pane.height != 700 - inset {
        return fail(
            "the pane is \(big.pane.height) tall in a 700pt window with a \(inset)pt band;"
                + " the band must be the 52pt unified title bar and the pane must start below it")
    }

    // THE ISLAND'S FRAME. It starts past the traffic lights, is as wide as its tabs, and
    // stops at the right margin. The narrow cases are the discriminating ones: a frame that
    // only adds `leading` and `ideal` is right at 1120 and runs off the window at 300.
    let room = big.band.width - TabMetrics.margin - 92
    let fits = TabMetrics.islandFrame(band: big.band, leading: 92, ideal: 300)
    if fits.minX != 92 || fits.width != 300 {
        return fail("an island that fits sits at \(fits)")
    }
    if fits.midY != big.band.midY {
        return fail("the island is not centred in the band: \(fits.midY) against \(big.band.midY)")
    }
    let crowded = TabMetrics.islandFrame(band: big.band, leading: 92, ideal: 5000)
    if crowded.width != room {
        return fail("a 5000pt island got \(crowded.width)pt; the room past the lights is \(room)")
    }
    let narrow = ChromeLayout.compute(content: NSSize(width: 60, height: 300)).band
    let squeezed = TabMetrics.islandFrame(band: narrow, leading: 92, ideal: 300)
    if squeezed.width != 0 || squeezed.maxX > narrow.maxX {
        return fail("in a 60pt window the island is \(squeezed); it must shrink to nothing inside")
    }

    // A LONG TITLE IS CUT, keeping both ends. Without the cut one `claude` title holds the
    // whole band and every other tab scrolls away.
    let long = "claude working in a very long directory name/feature-branch-tail"
    let cut = TabMetrics.clip(long)
    if cut.count != TabMetrics.maxTitle || !cut.contains("\u{2026}")
        || !long.hasPrefix(String(cut.prefix(5))) || !long.hasSuffix(String(cut.suffix(5)))
    {
        return fail("a long title clipped to \"\(cut)\"")
    }
    if TabMetrics.clip("zsh 1") != "zsh 1" {
        return fail("a short title was changed by the clip")
    }

    // THE CHORDS, as physical keys. The ANSI digit keyCodes are out of order (5 is 23, 6 is
    // 22), so a table written as arithmetic would swap two tabs and look right for the rest.
    let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
    for (code, number) in digits where TerminalView.tabNumber(for: code) != number {
        return fail("keyCode \(code) selects tab \(String(describing: TerminalView.tabNumber(for: code))), expected \(number)")
    }
    // cmd+T, cmd+0 (zoom reset) and cmd+W must not become tab chords.
    for code: UInt16 in [17, 29, 13] where TerminalView.tabNumber(for: code) != nil {
        return fail("keyCode \(code) was taken as a tab digit")
    }
    if TerminalView.tabStep(for: 30) != 1 || TerminalView.tabStep(for: 33) != -1
        || TerminalView.tabStep(for: 42) != nil
    {
        return fail("the bracket chords step the wrong way, or the split key steps tabs")
    }

    // THE TOP FADE stays inside the pane, at its top, and never takes a click: the first
    // row under it is still the pane's to select and cmd+click.
    let fadeRect = TopFadeView.frame(pane: big.pane)
    if fadeRect.maxY != big.pane.maxY || fadeRect.minY < big.pane.minY
        || fadeRect.width != big.pane.width || fadeRect.height != TopFadeView.height
    {
        return fail("the top fade sits at \(fadeRect) over a pane at \(big.pane)")
    }
    if TopFadeView.frame(pane: NSRect(x: 0, y: 0, width: 300, height: 5)).height > 5 {
        return fail("in a 5pt pane the top fade is taller than the pane")
    }
    let fadeView = TopFadeView(frame: NSRect(x: 0, y: 0, width: 300, height: TopFadeView.height))
    if fadeView.hitTest(NSPoint(x: 10, y: 5)) != nil {
        return fail("the top fade takes clicks meant for the first row")
    }
    // Deeper than the margin, or it fades nothing (16pt was tried and changed nothing on
    // screen); no deeper than the margin and about one row, or it veils output.
    if TopFadeView.height <= TerminalView.padding || TopFadeView.height > 40 {
        return fail("the top fade is \(TopFadeView.height)pt; it must reach past the margin and stop near one row")
    }

    // THE TOP BLUR STRIP (option 2) rises out of the pane from row 0's top, at its true
    // size: one pixel off and the row above the viewport floats over or under the first row.
    let stripBounds = NSRect(x: 0, y: 0, width: 640, height: 400)
    let strip = TerminalView.stripFrame(
        bounds: stripBounds, pixels: CGSize(width: 1200, height: 352), overlap: 132, scale: 2)
    if strip.minY != stripBounds.height - TerminalView.padding - 66 || strip.minX != TerminalView.padding
        || strip.width != 600 || strip.height != 176
    {
        return fail("the blur strip sits at \(strip) over a pane of \(stripBounds)")
    }
    // NODEE'S VEIL: 96pt from the window top, the strip's mask clear below it and opaque over
    // its top 45%. A mask with no clear part is the hard edge the maintainer rejected.
    let veil = TopVeil.frame(pane: stripBounds, band: ChromeLayout.topInset)
    if veil.maxY != stripBounds.height + ChromeLayout.topInset || veil.height != 96 || veil.width != stripBounds.width {
        return fail("the veil sits at \(veil) over a pane of \(stripBounds)")
    }
    let (clear, opaque) = TopVeil.mask(strip: strip, veil: veil)
    let clearY = strip.minY + clear * strip.height, opaqueY = strip.minY + opaque * strip.height
    if abs(clearY - veil.minY) > 0.01 || abs(opaqueY - (veil.maxY - 96 * 0.45)) > 0.01 || clear <= 0 || opaque <= clear {
        return fail("the strip's mask runs \(clearY) to \(opaqueY) under a veil of \(veil)")
    }
    // Only a pane whose top is the container's has the band above it. Side by side both do;
    // stacked, the lower one would lay its strip over the pane above it.
    let box = NSRect(x: 0, y: 0, width: 800, height: 600)
    let sideBySide = SplitLayout.tile(
        .branch(axis: .horizontal, fraction: 0.5, first: .leaf(1), second: .leaf(2)), in: box)
    let stacked = SplitLayout.tile(
        .branch(axis: .vertical, fraction: 0.5, first: .leaf(1), second: .leaf(2)), in: box)
    if SplitLayout.topPanes(sideBySide, in: box) != [1, 2] || SplitLayout.topPanes(stacked, in: box) != [1] {
        return fail("the strip's top panes are wrong: side by side \(SplitLayout.topPanes(sideBySide, in: box)), stacked \(SplitLayout.topPanes(stacked, in: box))")
    }

    // MOTION. Off, or under Reduce Motion, every change is instant (a nil animation); and only
    // a session ARRIVING at done, attention or error pings, never one that starts or is looked at.
    if Motion.spring(enabled: false, reduce: false) != nil || Motion.spring(enabled: true, reduce: true) != nil
        || Motion.spring(enabled: true, reduce: false) == nil
    {
        return fail("motion is not off when the switch or Reduce Motion says so")
    }
    if !Motion.pings(from: .working, to: .done) || !Motion.pings(from: .working, to: .attention)
        || !Motion.pings(from: .idle, to: .done) || Motion.pings(from: .idle, to: .working)
        || Motion.pings(from: .done, to: .idle) || Motion.pings(from: .working, to: .idle)
        || Motion.pings(from: .done, to: .done)
    {
        return fail("the finish ping fires on the wrong state changes")
    }

    // TRANSITIONS (M2). A panel scales about its own centre, not its corner, and travels by the
    // offset; leaving is quicker than arriving.
    let panel = CGRect(x: 0, y: 0, width: 560, height: 300)
    let settle = CATransform3DGetAffineTransform(
        Motion.centred(scale: 0.98, in: panel, offset: CGPoint(x: 0, y: 8)))
    let centre = CGPoint(x: panel.midX, y: panel.midY).applying(settle)
    let corner = CGPoint.zero.applying(settle)
    if abs(centre.x - 280) > 0.01 || abs(centre.y - 158) > 0.01
        || abs(corner.x - 5.6) > 0.01 || abs(corner.y - 11) > 0.01
    {
        return fail("the palette does not scale about its centre: centre \(centre), corner \(corner)")
    }
    if Motion.departure >= Motion.appear {
        return fail("the palette leaves slower than it arrives")
    }

    // GHOSTTY SPLITS. A one-point hairline with grab room ACROSS it (a side-by-side split's
    // line is grabbed sideways, a stacked split's vertically), drawn as the ground at 60%
    // brightness, and the unfocused wash at Ghostty's 1 - 0.7.
    let seamRoom = NSRect(x: 0, y: 0, width: 801, height: 400)
    let sideSeam = SplitLayout.dividers(
        .branch(axis: .horizontal, fraction: 0.5, first: .leaf(1), second: .leaf(2)), in: seamRoom)[0]
    let stackSeam = SplitLayout.dividers(
        .branch(axis: .vertical, fraction: 0.5, first: .leaf(1), second: .leaf(2)), in: seamRoom)[0]
    let sideGrab = SplitLayout.grabRect(sideSeam)
    let stackGrab = SplitLayout.grabRect(stackSeam)
    if sideSeam.rect.width != 1 || stackSeam.rect.height != 1
        || sideGrab.width != 7 || sideGrab.height != sideSeam.rect.height
        || stackGrab.height != 7 || stackGrab.width != stackSeam.rect.width
    {
        return fail("the split hairline or its grab room is wrong: \(sideSeam.rect) \(sideGrab), \(stackSeam.rect) \(stackGrab)")
    }
    let hair = SplitLook.line(ground: NSColor(srgbRed: 0.5, green: 0.25, blue: 0.25, alpha: 1))
        .usingColorSpace(.sRGB)
    if hair == nil || abs(hair!.redComponent - 0.3) > 0.005 || abs(hair!.greenComponent - 0.15) > 0.005
        || SplitLook.dim != 0.3
    {
        return fail("the hairline is not the ground at 60% brightness, or the wash is not 0.3")
    }

    // THE CARET LAYER (M3). The caret's cell in bottom-up points: the grid starts at the top
    // padding edge, so row 0 is the top row and each row below sits one cell lower.
    let caretBox = NSRect(x: 0, y: 0, width: 400, height: 300)
    let caretAt = TerminalView.caretFrame(
        bounds: caretBox, column: 2, row: 0, cell: CGSize(width: 16, height: 32), scale: 2)
    let caretBelow = TerminalView.caretFrame(
        bounds: caretBox, column: 2, row: 1, cell: CGSize(width: 16, height: 32), scale: 2)
    if caretAt != CGRect(x: 24, y: 276, width: 8, height: 16) || caretBelow.minY != 260 {
        return fail("the caret layer is off its cell: row 0 at \(caretAt), row 1 at \(caretBelow)")
    }
    if Motion.glide > 0.1 || Motion.caretRest <= 0 || Motion.blink < 0.8 {
        return fail("the caret glide trails typing, or the blink has no rest or flickers")
    }

    // PIXEL SCROLLING (M4). Rows of 20pt, eight lead rows. A climb shifts the drawn grid and
    // asks nothing until it is a row past the headroom; a landing takes the landed rows off
    // the offset so the picture holds still; rest is always a whole row, then zero.
    var scroll = PixelScroll()
    if scroll.move(by: 30, row: 20, viewport: 0, above: 8, lead: 8) != 0 || scroll.shown(row: 20, above: 8) != 30 {
        return fail("a 30pt climb asked rows or did not shift the grid 30pt")
    }
    let climb = scroll.move(by: 40, row: 20, viewport: 0, above: 8, lead: 8)
    if climb != 1 || scroll.offset != 70 {
        return fail("70pt up asked \(climb) rows at offset \(scroll.offset), expected 1 at 70")
    }
    if scroll.move(by: 25, row: 20, viewport: 0, above: 8, lead: 8) != 0 {
        return fail("asked again while a row was still in flight")
    }
    scroll.landed(viewport: 1, row: 20)
    if scroll.offset != 75 || scroll.asked != 0 {
        return fail("the landed row did not come off the offset: \(scroll.offset), \(scroll.asked) asked")
    }
    // The way back: under the headroom the grid steps down so rows below are never missing.
    let back = scroll.move(by: -40, row: 20, viewport: 1, above: 8, lead: 8)
    if back != -1 {
        return fail("heading for the live bottom at 35pt asked \(back) rows, expected -1")
    }
    scroll.landed(viewport: 0, row: 20)
    if scroll.move(by: -200, row: 20, viewport: 0, above: 8, lead: 8) != 0 || scroll.offset != 0 {
        return fail("the live bottom let the offset go to \(scroll.offset)")
    }
    // The oldest row: two real rows above, so the offset stops at 40pt however far it climbs.
    var top = PixelScroll()
    _ = top.move(by: 500, row: 20, viewport: 40, above: 2, lead: 8)
    if top.shown(row: 20, above: 2) != 40 {
        return fail("climbed past the oldest row to \(top.offset)")
    }
    // Rest: 47pt glides to 40 (two rows), asks two, and lands at zero.
    var rest = PixelScroll()
    _ = rest.move(by: 47, row: 20, viewport: 5, above: 8, lead: 8)
    let glideTo = rest.rest(row: 20, viewport: 5, above: 8)
    let settled = rest.settle(row: 20, viewport: 5)
    rest.landed(viewport: 7, row: 20)
    if glideTo != 40 || settled != 2 || rest.offset != 0 || rest.resting {
        return fail("rest glided to \(glideTo), asked \(settled), left \(rest.offset) resting \(rest.resting)")
    }
    // At the live bottom, where there is no headroom to keep, an 8pt nudge glides back.
    var tiny = PixelScroll()
    _ = tiny.move(by: 8, row: 20, viewport: 0, above: 8, lead: 8)
    if tiny.rest(row: 20, viewport: 0, above: 8) != 0 || tiny.settle(row: 20, viewport: 0) != 0
        || tiny.resting
    {
        return fail("an 8pt nudge did not glide back to its own row")
    }
    // A pane at rest does not read the lead rows: that read was a lead image per streaming
    // frame for rows nobody could see. A gesture reads them itself when it begins.
    let resting = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    resting.pixelScrolling = true
    if resting.needsLead {
        return fail("a pane at rest reads the lead rows every frame")
    }

    // THE SQUEEZE. Tabs that fit keep their natural size; tabs that do not all shrink to one
    // equal width, and never below the floor, where the strip scrolls instead.
    if TabMetrics.squeeze(natural: 400, room: 700, count: 5) != nil {
        return fail("five tabs that fit were squeezed")
    }
    let even = TabMetrics.squeeze(natural: 900, room: 700, count: 5) ?? 0
    if even * 5 + TabMetrics.spacing * 4 > 700 || even < TabMetrics.minChipWidth {
        return fail("five tabs in 700pt squeezed to \(even)pt each, which does not fit")
    }
    if TabMetrics.squeeze(natural: 4000, room: 700, count: 40) != TabMetrics.minChipWidth {
        return fail("forty tabs squeezed below the \(TabMetrics.minChipWidth)pt floor")
    }

    // THE WHEEL. A strip that scrolls only sideways ignores an ordinary mouse wheel, which is
    // how fourteen tabs became unreachable. The vertical delta must come out horizontal and
    // the vertical one must be gone, or the strip and the window both move.
    guard let down = CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0),
        let wheel = NSEvent(cgEvent: down)
    else { return fail("could not build a wheel event") }
    let turned = TabWheel.sideways(wheel)
    if turned.scrollingDeltaX != wheel.scrollingDeltaY || turned.scrollingDeltaY != 0 {
        return fail(
            "the wheel came out as (\(turned.scrollingDeltaX), \(turned.scrollingDeltaY)),"
                + " expected (\(wheel.scrollingDeltaY), 0)")
    }
    if wheel.scrollingDeltaY == 0 {
        return fail("the test wheel itself carries no delta; the assertion above proves nothing")
    }

    // THE MODEL PUBLISHES ONLY ON A CHANGE. A working agent repeats its title several times
    // a second, and a publish per repeat re-renders the whole island for nothing.
    let model = TabModel()
    var publishes = 0
    let watch = model.objectWillChange.sink { _ in publishes += 1 }
    let item = TabItem(id: 1, title: "zsh 1", detail: "", state: .idle)
    model.update(items: [item], active: 0)
    let first = publishes
    model.update(items: [item], active: 0)
    watch.cancel()
    if first == 0 || publishes != first {
        return fail("the tab model published \(first) then \(publishes - first) times for a repeat")
    }

    // EVERY CHROME COLOUR IS ACHROMATIC. The maintainer's call 2026-08-25: the chrome must not
    // assert a hue while the terminal beside it paints whatever the child asked for, and
    // there is no shared source to sync them to until Themes exists.
    //
    // The assertion is on `ChromeColor`, which is now the only place a chrome colour is
    // written. It CANNOT see a colour hardcoded somewhere else -- that is the stated limit
    // of this gate, and the reason the four private palettes were collapsed into one type
    // first. `NSColor(white:)` makes a hue inexpressible, so this catches the case where
    // somebody widens the type to take components.
    // BOTH constructors. `over()` is the one every surface uses now, and a hue smuggled
    // into it would reach the whole dock while `of()` stayed innocent.
    for level in ChromeColor.all {
        for (name, colour) in [("of", ChromeColor.of(level)), ("over", ChromeColor.over(level))] {
            guard let rgb = colour.usingColorSpace(.sRGB) else {
                return fail("chrome level \(level) via \(name) did not convert to sRGB")
            }
            let (r, g, b) = (rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
            if abs(r - g) > 0.001 || abs(g - b) > 0.001 {
                return fail(
                    "chrome level \(level) via \(name) is not grey: r \(r), g \(g), b \(b)")
            }
        }
    }
    // `over` must be WHITE at an alpha, not a grey at full alpha. That is what makes the
    // dock take the terminal's hue instead of asserting one: a grey painted opaque over a
    // blue ground is grey, and the seam the maintainer reported comes straight back.
    for level in ChromeColor.all {
        guard let rgb = ChromeColor.over(level).usingColorSpace(.sRGB) else {
            return fail("over(\(level)) did not convert to sRGB")
        }
        // The components, not `whiteComponent`: that accessor raises on an sRGB colour.
        if abs(rgb.alphaComponent - level) > 0.001 || rgb.redComponent < 0.999
            || rgb.greenComponent < 0.999 || rgb.blueComponent < 0.999
        {
            return fail(
                "over(\(level)) is (\(rgb.redComponent), \(rgb.greenComponent),"
                    + " \(rgb.blueComponent)) at alpha \(rgb.alphaComponent);"
                    + " it must be pure white at the level")
        }
    }
    // The ramp must be a RAMP. Two levels that collapsed to the same grey would make a
    // selected row indistinguishable from a resting one, which no achromatic assertion
    // above can see.
    if Set(ChromeColor.all.map { Int($0 * 1000) }).count != ChromeColor.all.count {
        return fail("two chrome levels are the same grey; the ramp has a collision")
    }
    // Text on ground has to be readable. A ramp is easy to make tasteful and unreadable.
    if ChromeColor.text - ChromeColor.ink < 0.5 {
        return fail(
            "text (\(ChromeColor.text)) against ink (\(ChromeColor.ink)) is too close")
    }
    if ChromeColor.textMuted - ChromeColor.ink < 0.25 {
        return fail(
            "muted text (\(ChromeColor.textMuted)) against ink (\(ChromeColor.ink)) is too close")
    }
    // The five states must be five DIFFERENT marks. Hue used to carry this; shape does now,
    // and shape is the thing a greyscale ramp cannot fall back on.
    let states: [Session.WorkState] = [.idle, .working, .done, .error, .attention]
    let shapes = states.map { StateDot.mark($0).shape }
    if Set(shapes.map { "\($0)" }).count != states.count {
        return fail("the \(states.count) work states draw only \(Set(shapes.map { "\($0)" }).count) marks")
    }
    if StateDot.mark(.idle).shape != .none || StateDot.mark(.idle).level != 0 {
        return fail("idle draws something; it is the absence of a mark")
    }
    // The state that means STOPPED must be the brightest mark there is.
    for quieter in [Session.WorkState.working, .done] {
        if StateDot.mark(.attention).level <= StateDot.mark(quieter).level {
            return fail(
                "attention is drawn at \(StateDot.mark(.attention).level), no brighter than"
                    + " \(quieter) at \(StateDot.mark(quieter).level)")
        }
    }
    if StateDot.mark(.attention).level <= 0 {
        return fail("the attention mark paints nothing; it is the one state that must be seen")
    }

    // Joined rather than a `+` chain: Swift 6.4 gives up type-checking a chain this long.
    print(
        [
            "CHROME SMOKE OK: pane and band stack exactly at \(widths.count)x\(heights.count)",
            " sizes down to 0pt, the \(Int(inset))pt band holds the top, the island fits,",
            " clamps at \(Int(room))pt and shrinks to nothing in a 60pt window, long titles",
            " cut to \(TabMetrics.maxTitle), tabs squeeze evenly to a \(Int(TabMetrics.minChipWidth))pt",
            " floor, a vertical wheel turns sideways,",
            " cmd+1..9 and cmd+shift+[ ] map by physical key,",
            " the model skips a repeat publish, \(ChromeColor.all.count) chrome levels all",
            " achromatic and white-over-ground, \(states.count) distinct state marks with",
            " attention the brightest",
        ].joined())
    return 0
}

/// `--smoke-workstate`: what a program's TITLE says about whether it is working.
///
/// Written because the table it checks was WRONG and nothing could see it. `classify` lived
/// inside `Session`, keyed on a private dictionary, reachable only from a session with a live
/// pty, so it had never been asserted once. Two of the three spinner glyphs Claude Code
/// actually puts in its title were missing, and the failure is silent and backwards: the dock
/// announced DONE every time the spinner landed on one of them, while the agent was working.
///
/// The titles below are MEASURED, not invented. Captured 2026-08-26 off a real pty running
/// Claude Code v2.1.246, by logging every `OSC 0` it emitted across a session that answered a
/// trust prompt and ran a command. Three distinct leading glyphs appeared and two of them
/// were unknown to the table.
/// The mouse-selection gesture rule, and the one chord that must NOT be swallowed.
///
/// Selection existed in `Session` (Rust) and in nothing else: no caller, no test, and no C
/// export, so the app could not select text with a mouse at all. The engine half is gated by
/// `crates/host/tests/selection_abi.rs` through the real C surface; this is the host half,
/// which is the click count and the cmd+C fallthrough.
func runSelectionSmoke() -> Int32 {
    func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("selection smoke: \(message)\n".utf8))
        return 1
    }

    // One click arms a drag. Two is a word. Three is a line, and so is four: AppKit keeps
    // counting inside the double-click interval, and a fast hand must not lose its line.
    let table: [(Int, SelectGesture.Kind)] = [
        (1, .arm), (2, .word), (3, .line), (4, .line), (7, .line),
    ]
    for (clicks, want) in table {
        let got = SelectGesture.decide(clicks: clicks)
        if got != want {
            return fail(
                "\(clicks) clicks answered \(got) and the gesture is \(want)")
        }
    }

    // A click count of zero happens: AppKit reports it for a synthesized or replayed event,
    // and anything but `arm` there would select a word nobody asked for.
    if SelectGesture.decide(clicks: 0) != .arm {
        return fail("a click count of 0 must arm a drag, not select anything")
    }

    // ONLY a single click arms a drag. A drag that began as a double-click must not collapse
    // the word back to one cell on the first pixel of tremor.
    if !SelectGesture.extends(.arm) {
        return fail("a single click did not arm a drag, so nothing can ever be dragged")
    }
    if SelectGesture.extends(.word) || SelectGesture.extends(.line) {
        return fail(
            "a double or triple click armed a drag; the next pointer move would collapse the"
                + " word or line it just selected into a one-cell range")
    }

    // The distinctness check, which the three rules above would pass VACUOUSLY if `decide`
    // returned one constant: a rule that answered `.line` to everything satisfies two of the
    // three rows above and is caught only here.
    let kinds = Set([1, 2, 3].map { SelectGesture.decide(clicks: $0) })
    if kinds.count != 3 {
        return fail(
            "one, two and three clicks produced \(kinds.count) distinct gestures, not 3")
    }

    // A cmd+click into a window that is not key is macOS's "act without activating" click.
    // AppKit delivers it to the view only when the view accepts first mouse; refusing
    // swallowed every cmd+click made while another app was in front (2026-10-02). A plain
    // click stays refused, so the click that brings the window forward never selects.
    let pane = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    func click(_ flags: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1,
            pressure: 1)
    }
    if !pane.acceptsFirstMouse(for: click(.command)) {
        return fail("a cmd+click into an inactive window is refused, so it never reaches the pane")
    }
    if pane.acceptsFirstMouse(for: click([])) {
        return fail("a plain click into an inactive window is accepted, so activating it selects")
    }

    let ok =
        "SELECTION SMOKE OK: 1 click arms, 2 words, 3+ lines, and only an armed drag extends\n"
    FileHandle.standardError.write(Data(ok.utf8))
    return 0
}

func runWorkStateSmoke() -> Int32 {
    func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("workstate smoke: \(message)\n".utf8))
        return 1
    }

    // Every one of these was on the wire. `\u{25D0}` and `\u{25D1}` are the two that were
    // missing, and they are why this file exists.
    let measured = [
        "\u{2733} Claude Code", "\u{2733} Date command",
        "\u{25D0} Claude Code", "\u{25D0} Date command",
        "\u{25D1} Claude Code", "\u{25D1} Date command",
    ]
    for title in measured {
        let seen = WorkStateRule.decide(cli: "claude", title: title, current: .idle)
        if seen != .working {
            return fail(
                "the title \(title.debugDescription) was on the wire from Claude Code and this"
                    + " rule answers \(String(describing: seen)) instead of working;"
                    + " the dock reports the opposite of the truth while an agent runs")
        }
    }
    // The body glyphs, kept so the older half of the table cannot be dropped by someone
    // tidying up after reading only the paragraph above.
    for glyph in ["\u{2736}", "\u{273B}", "\u{273D}"] {
        if WorkStateRule.decide(cli: "claude", title: "\(glyph) Working", current: .idle)
            != .working
        {
            return fail("the measured body glyph \(glyph.debugDescription) no longer classifies")
        }
    }

    // THE CONTROL, and without it every assertion above passes on a rule that answers
    // `.working` to everything. A title with no marker must still be able to end a run.
    if WorkStateRule.decide(cli: "claude", title: "Claude Code", current: .working) != .done {
        return fail("a title with no marker cannot end a run; the rule only ever says working")
    }
    // And it must not INVENT an ending. From idle, an unmarked title is not news.
    if WorkStateRule.decide(cli: "claude", title: "Claude Code", current: .idle) != nil {
        return fail("an unmarked title moved an idle session; nil means leave it alone")
    }
    // A CLI with no table never classifies, because a title that was never a signal must not
    // overwrite the OSC 9;4 progress that outranks it.
    for title in measured + ["anything"] {
        if WorkStateRule.decide(cli: "some-other-cli", title: title, current: .working) != nil {
            return fail("a CLI with no marker table classified anyway, off another CLI's glyph")
        }
    }
    // THE FIFTH STATE. A bell is the only explicit "I need you" a terminal gets, measured
    // 2026-08-26: frozen on a permission prompt Claude Code sends no title, no `OSC 9;4` and
    // no bell of its own, so nothing softer than BEL was available and a timer was refused.
    for from in [Session.WorkState.idle, .working, .done, .error, .attention] {
        if WorkStateRule.rang(current: from) != .attention {
            return fail("a bell from a \(from) session did not raise attention")
        }
    }
    // STICKY, and this is the assertion the state stands on. A bell means the session has
    // STOPPED. Anything that arrives afterwards is the program repainting, not the operator
    // answering, so nothing on the wire may clear it -- only looking at the pane does.
    for title in measured + ["Claude Code", ""] {
        if WorkStateRule.decide(cli: "claude", title: title, current: .attention) != nil {
            return fail(
                "the title \(title.debugDescription) cleared an attention state; only the"
                    + " operator looking at the pane may do that")
        }
    }
    for progress in [UInt8(0), 1, 2, 3, 4] {
        if WorkStateRule.afterProgress(progress, current: .attention) != .attention {
            return fail("OSC 9;4 state \(progress) cleared an attention state")
        }
    }
    // THE CONTROL for stickiness: the same function must still move a session that is NOT
    // waiting, or "sticky" would just be "this function never returns anything".
    if WorkStateRule.afterProgress(2, current: .working) != .error {
        return fail("OSC 9;4 error no longer reaches a working session; sticky ate everything")
    }
    if WorkStateRule.decide(cli: "claude", title: measured[0], current: .idle) != .working {
        return fail("a busy title no longer reaches an idle session")
    }
    // And looking at the pane DOES clear it, or the badge is permanent.
    if WorkStateRule.afterSeen(.attention) != .idle {
        return fail("looking at the pane did not clear attention; the badge would be permanent")
    }
    if WorkStateRule.afterSeen(.working) != .working {
        return fail("looking at a pane cleared a state that was not a badge")
    }

    // A duplicate or empty marker is a typo that would never show up as a wrong answer.
    let glyphs = WorkStateRule.busyMarkers.values.flatMap { $0 }
    if glyphs.contains(where: \.isEmpty) {
        return fail("an empty marker matches every title")
    }
    if Set(glyphs).count != glyphs.count {
        return fail("a marker is listed twice")
    }

    print(
        "WORKSTATE SMOKE OK: \(measured.count) titles measured off a real Claude Code pty all"
            + " classify as working, the \(glyphs.count) markers are distinct and non-empty, an"
            + " unmarked title ends a run but does not invent one, a CLI with no table never"
            + " classifies, and a bell raises an attention that nothing on the wire can"
            + " clear")
    return 0
}

/// `--smoke-offline`: the panel is the only part of Termisu that CAN reach the network,
/// and this is what stops it.
///
/// The README says Termisu makes no network connections. The Rust half of that claim is
/// `crates/host/tests/no_network.rs`, which reads the resolved dependency graph. This is
/// the other half, and it is the harder one, because the panel embeds WebKit: the ability
/// to open a socket is linked into the process whether we want it or not. What makes the
/// claim true anyway is that the webview is never allowed to navigate anywhere except the
/// one local document it was handed.
///
/// The policy used to live inside `decidePolicyFor`, where it could not be reached without
/// a `WKNavigationAction`, and that type has no public initialiser. So it had never been
/// asserted -- the same shape as `Session.classify` before `WorkStateRule`, and that one
/// turned out to be wrong in a way nothing could see.
func runOfflineSmoke() -> Int32 {
    func fail(_ why: String) -> Int32 {
        FileHandle.standardError.write(Data("OFFLINE SMOKE FAILED: \(why)\n".utf8))
        return 1
    }

    let document = "/tmp/termisu-panel/index.html"
    let documentURL = URL(fileURLWithPath: document)

    // The one thing that is allowed, and it has to be, or "refuses everything" is trivially
    // satisfied by a panel that never loads at all. A control, not a courtesy.
    if !PanelNavigation.allows(url: documentURL, type: .other, documentPath: document) {
        return fail("the panel refused its OWN document; nothing would ever render")
    }

    // Remote origins. This is the whole point: a link in rendered content -- a URL in a
    // commit message, a path in a diff -- must not be able to pull a remote page into the
    // terminal's process.
    let remote = [
        "https://example.com",
        "http://127.0.0.1:8080/",
        "ws://example.com/socket",
        "about:blank",
        "data:text/html,<b>hi</b>",
        "javascript:alert(1)",
        "file:///etc/passwd",
        "file:///tmp/termisu-panel/other.html",
    ]
    for text in remote {
        guard let url = URL(string: text) else {
            return fail("the fixture \(text) is not a URL; the case proves nothing")
        }
        if PanelNavigation.allows(url: url, type: .other, documentPath: document) {
            return fail("the panel would navigate to \(text)")
        }
    }

    // THE CASE A MUTANT FOUND, and it is the reason `isFileURL` is in the guard rather
    // than being decoration. Drop that check and every fixture above is still refused --
    // but only by the PATH comparison, and a remote URL can carry any path it likes.
    // `https://evil.example/tmp/termisu-panel/index.html` resolves to exactly the document
    // path, and the panel would have loaded a remote origin inside the terminal's process.
    for scheme in ["https", "http", "ftp"] {
        guard let impostor = URL(string: "\(scheme)://evil.example\(document)") else {
            return fail("could not build the \(scheme) impostor fixture")
        }
        if PanelNavigation.allows(url: impostor, type: .other, documentPath: document) {
            return fail(
                "a remote URL carrying the document's own path was allowed: \(impostor)")
        }
    }

    // A nil URL is not an excuse to allow.
    if PanelNavigation.allows(url: nil, type: .other, documentPath: document) {
        return fail("a navigation with no URL at all was allowed")
    }

    // And the TYPE matters independently of the path. The document's own URL arriving as a
    // clicked link is a page trying to reload itself through a gesture, which is not how the
    // panel is loaded, and allowing it would make the type check dead code.
    for type in [
        WKNavigationType.linkActivated, .formSubmitted, .backForward, .reload, .formResubmitted,
    ] {
        if PanelNavigation.allows(url: documentURL, type: type, documentPath: document) {
            return fail("navigation type \(type.rawValue) reached the document; only .other may")
        }
    }

    // A symlink must not be a way around the path comparison.
    let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("termisu-offline-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let real = temporary.appendingPathComponent("real.html")
    let link = temporary.appendingPathComponent("link.html")
    FileManager.default.createFile(atPath: real.path, contents: Data("<b>x</b>".utf8))
    try? FileManager.default.removeItem(at: link)
    try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    defer { try? FileManager.default.removeItem(at: temporary) }
    if !PanelNavigation.allows(url: link, type: .other, documentPath: real.resolvingSymlinksInPath().path) {
        return fail("a symlink to the document was refused; the path comparison is not resolving")
    }
    if PanelNavigation.allows(url: real, type: .other, documentPath: link.path) {
        return fail("an unresolved symlink path was accepted as the document path")
    }

    print(
        "OFFLINE SMOKE OK: the panel loads its own document and refuses \(remote.count) other"
            + " origins, three remote impostors carrying the document's own path, five"
            + " navigation types, a nil URL, and an unresolved symlink path")
    return 0
}

/// `--smoke-bell`: the visual bell's policy, and that a burst of bells is ONE flash.
///
/// The coalescing half is the reason this gate exists at all. A wash per bell stacks their
/// opacities, and a shell that rings in a loop -- which is exactly what a failing build
/// script does -- would white the pane out and keep it white. That failure is invisible to
/// every other gate here and would only ever be found by someone watching it happen.
func runBellSmoke() -> Int32 {
    func fail(_ why: String) -> Int32 {
        FileHandle.standardError.write(Data("BELL SMOKE FAILED: \(why)\n".utf8))
        return 1
    }

    // Faint but present. Both ends matter: 0 is not a bell, and a bright one is a strobe.
    if BellFlash.peak < 0.05 || BellFlash.peak > 0.22 {
        return fail("peak opacity \(BellFlash.peak) is outside the band a faint wash lives in")
    }
    // Brief. A long fade reads as the terminal being broken rather than as a bell.
    if BellFlash.duration < 0.08 || BellFlash.duration > 0.25 {
        return fail("a \(BellFlash.duration)s fade is not a flash")
    }

    let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    view.layoutSubtreeIfNeeded()
    let before = view.layer?.sublayers?.count ?? 0

    view.flashBell()
    guard let flash = view.bellWash else {
        return fail("ringing the bell created no wash layer")
    }
    let after = view.layer?.sublayers?.count ?? 0
    if after != before + 1 {
        return fail("one bell added \(after - before) layers, not one")
    }
    if flash.animation(forKey: BellFlash.animationKey) == nil {
        return fail("the wash layer carries no fade; it would sit there at peak forever")
    }
    // The MODEL value stays transparent, so when the fade ends the pane is not left tinted.
    if flash.opacity != 0 {
        return fail("the wash's resting opacity is \(flash.opacity); the pane stays washed")
    }
    if flash.frame.width <= 0 || flash.frame.height <= 0 {
        return fail("the wash has no area: \(flash.frame)")
    }

    // Achromatic, the same law the rest of the chrome lives under -- and read off the LAYER
    // ITSELF, not off `BellFlash.level`. Checking the policy is what `--smoke-chrome` can do
    // and its stated limit is that it cannot see a colour hardcoded elsewhere. It is not a
    // limit here, because the real layer is in hand: a systemRed mutant PASSED the policy
    // version of this check on the first run.
    guard let painted = flash.backgroundColor,
        let wash = NSColor(cgColor: painted)?.usingColorSpace(.sRGB)
    else {
        return fail("the wash layer has no readable sRGB background colour")
    }
    if wash.redComponent != wash.greenComponent || wash.greenComponent != wash.blueComponent {
        return fail(
            "the wash the layer actually paints is chromatic: r=\(wash.redComponent)"
                + " g=\(wash.greenComponent) b=\(wash.blueComponent)")
    }
    if abs(wash.redComponent - BellFlash.level) > 0.001 {
        return fail(
            "the layer paints level \(wash.redComponent) but the policy says"
                + " \(BellFlash.level); the constant is not what reaches the screen")
    }

    // THE COALESCING ASSERTION. Twenty bells in a row are one wash and one fade.
    for _ in 0..<20 { view.flashBell() }
    let burst = view.layer?.sublayers?.count ?? 0
    if burst != after {
        return fail("20 bells left \(burst - before) layers; a burst stacks instead of coalescing")
    }
    if view.bellWash !== flash {
        return fail("a second bell replaced the wash layer instead of restarting its fade")
    }
    if flash.animationKeys()?.count != 1 {
        return fail(
            "the wash carries \(flash.animationKeys()?.count ?? 0) animations after a burst;"
                + " they stack and their opacities add")
    }

    print(
        "BELL SMOKE OK: the wash is achromatic at level \(BellFlash.level), peaks at"
            + " \(BellFlash.peak) for \(BellFlash.duration)s, rests at zero, and 21 bells"
            + " leave exactly one layer carrying exactly one fade")
    return 0
}

/// `--smoke-ssh`: parses a fixture ssh_config and asserts what the palette will offer.
///
/// It writes its own config tree rather than reading the operator's, for two reasons. The
/// obvious one is determinism. The other is that `~/.ssh` is a credential directory and a
/// gate that reads it would print its contents into CI output the first time it failed.
///
/// The discriminating cases are the ones a naive line-splitter gets wrong: a wildcard
/// pattern is not a host, a second block for the same alias must LOSE, a `Match` block's
/// keys must not stick to the host above it, and an `Include` must be followed in place.
/// A parser that simply collected every `Host` word would pass none of them, and a parser
/// that collected the LAST value for each keyword would pass everything except one line.
func runSSHSmoke() -> Int32 {
    func fail(_ why: String) -> Int32 {
        FileHandle.standardError.write(Data("ssh smoke: \(why)\n".utf8))
        return 1
    }

    let root = NSTemporaryDirectory() + "termisu-ssh-smoke-\(getpid())"
    let includes = root + "/includes"
    defer { try? FileManager.default.removeItem(atPath: root) }
    do {
        try FileManager.default.createDirectory(
            atPath: includes, withIntermediateDirectories: true)
        // Written with real tabs and a `Key=Value` line because both appear in configs
        // people actually have, and both are places a hand-rolled split goes wrong.
        try """
            # a comment, then a blank line

            Host bastion
            \tHostName bastion.example.net
            \tUser user
            \tPort 2222

            Host *.internal !secret.internal
            \tUser nobody

            Host=compact
            \tHostName=10.0.0.9

            Include includes/*.conf

            Host bastion
            \tUser loser
            \tPort 9999

            Host tail
            \tHostName tail.example.net

            Match host tail
            \tUser stranger

            Host *
            \tUser everyone
            """.write(toFile: root + "/config", atomically: true, encoding: .utf8)
        try """
            Host inner
            \tHostName inner.example.net
            \tUser innerguy
            \tPort 22
            """.write(toFile: includes + "/extra.conf", atomically: true, encoding: .utf8)
    } catch {
        return fail("could not write the fixture: \(error)")
    }

    let hosts = SSHConfig.hosts(configPath: root + "/config")

    // Order AND membership in one assertion. `*.internal` and `!secret.internal` are
    // matchers, `*` is a matcher, and `inner` proves the Include was followed at the
    // point it appeared rather than appended at the end.
    let aliases = hosts.map(\.alias)
    if aliases != ["bastion", "compact", "inner", "tail"] {
        return fail("aliases were \(aliases), expected [bastion, compact, inner, tail]")
    }

    guard let bastion = hosts.first(where: { $0.alias == "bastion" }) else {
        return fail("bastion missing after the alias check passed")
    }
    // The second `Host bastion` block says loser/9999. ssh takes the FIRST value.
    if bastion.user != "user" || bastion.port != 2222 {
        return fail(
            "bastion resolved to user \(bastion.user ?? "nil") port"
                + " \(bastion.port.map(String.init) ?? "nil") -- the later duplicate block won,"
                + " so first-value-wins is inverted")
    }
    if bastion.hostName != "bastion.example.net" {
        return fail("bastion hostname is \(bastion.hostName ?? "nil")")
    }

    guard let compact = hosts.first(where: { $0.alias == "compact" }),
        compact.hostName == "10.0.0.9"
    else { return fail("the Key=Value form did not parse") }

    guard let inner = hosts.first(where: { $0.alias == "inner" }),
        inner.user == "innerguy", inner.hostName == "inner.example.net"
    else { return fail("the included host parsed without its fields") }

    guard let tail = hosts.first(where: { $0.alias == "tail" }) else {
        return fail("tail missing")
    }
    // Two separate leaks land on this one host: the `Match` block directly below it, and
    // the trailing `Host *`. Either one attaching would put a stranger's name on the row.
    if tail.user != nil {
        return fail(
            "tail picked up user \(tail.user ?? "") -- a Match block or a wildcard Host"
                + " attached its keys to the host above it")
    }

    // The subtitle is what the operator actually reads, so it is asserted, not assumed.
    if bastion.summary != "user@bastion.example.net:2222" {
        return fail("bastion summary is \(bastion.summary)")
    }
    if inner.summary != "innerguy@inner.example.net" {
        return fail("inner summary is \(inner.summary) -- port 22 should be left unsaid")
    }

    // THE CONTROL. Not having an ssh config is the normal state of a machine, and it must
    // read as an empty list rather than as a failure. Without this the whole feature could
    // be crashing on a fresh machine while every assertion above passed.
    if !SSHConfig.hosts(configPath: root + "/does-not-exist").isEmpty {
        return fail("a missing config produced hosts")
    }

    print(
        "SSH SMOKE OK: \(hosts.count) hosts from a config with an Include, wildcard and"
            + " negation patterns refused, a duplicate block lost to first-value-wins,"
            + " a Match block stayed off the host above it, missing config gave nothing")
    return 0
}

/// `--smoke-ssh-write`: the connection form's writer, against a fixture config.
///
/// This gate guards a MUTATION of a file the app did not author, in a credential
/// directory, so its assertions are about damage rather than about features. In order of
/// how bad the failure is: a newline smuggled through any field would append a second
/// block to the operator's config (a `Host *` stanza applies to every machine they own);
/// a rewrite instead of an append would put every existing host at the mercy of this
/// code; a duplicate alias would produce a saved host that behaves as though its settings
/// were ignored, because ssh takes the first value it obtains.
///
/// It also asserts the file mode, because `~/.ssh/config` created world-readable is a
/// problem that surfaces much later as ssh refusing a key with an error naming the key.
func runSSHWriteSmoke() -> Int32 {
    func fail(_ why: String) -> Int32 {
        FileHandle.standardError.write(Data("ssh write smoke: \(why)\n".utf8))
        return 1
    }

    let root = NSTemporaryDirectory() + "termisu-ssh-write-smoke-\(getpid())"
    let path = root + "/config"
    defer { try? FileManager.default.removeItem(atPath: root) }
    let existing = """
        Host already-here
        \tHostName first.example.net
        \tUser first
        """
    do {
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        // Deliberately written with NO trailing newline: appending to a file whose last
        // line is unterminated is the case that joins two directives into one.
        try existing.write(toFile: path, atomically: true, encoding: .utf8)
    } catch {
        return fail("could not write the fixture: \(error)")
    }

    // THE INJECTION CASE. Refused, not sanitised: silently stripping the newline would
    // save something other than what was typed, and the operator would not be told.
    var attack = SSHConnection()
    attack.alias = "innocent"
    attack.hostName = "box.example.net\nHost *\n    User root"
    if case .success = SSHConfig.append(attack, configPath: path) {
        return fail("a hostname carrying a newline was ACCEPTED -- that appends a global "
            + "Host * block to the operator's config")
    }
    // Every field, not just the obvious one: the injection works from any of them.
    for (name, mutate) in [
        ("user", { (c: inout SSHConnection) in c.user = "me\nHost *" }),
        ("identityFile", { (c: inout SSHConnection) in c.identityFile = "k\nHost *" }),
        ("proxyJump", { (c: inout SSHConnection) in c.proxyJump = "j\nHost *" }),
        ("remoteCommand", { (c: inout SSHConnection) in c.remoteCommand = "ls\nHost *" }),
    ] {
        var probe = SSHConnection()
        probe.alias = "probe-\(name)"
        probe.hostName = "box.example.net"
        mutate(&probe)
        if case .success = SSHConfig.append(probe, configPath: path) {
            return fail("a newline in \(name) was accepted")
        }
    }

    // A duplicate alias must be refused. ssh takes the FIRST value, so a second block is
    // shadowed and looks like settings that did nothing.
    var duplicate = SSHConnection()
    duplicate.alias = "already-here"
    duplicate.hostName = "second.example.net"
    if case .success = SSHConfig.append(duplicate, configPath: path) {
        return fail("a duplicate alias was appended; ssh would shadow it silently")
    }

    // Nothing above should have touched the file at all.
    guard let afterRefusals = try? String(contentsOfFile: path, encoding: .utf8),
        afterRefusals == existing
    else { return fail("a REFUSED write still modified the file") }

    var good = SSHConnection()
    good.alias = "prod"
    good.hostName = "prod.example.net"
    good.user = "user"
    good.port = "2222"
    good.identityFile = "~/.ssh/id_prod"
    good.proxyJump = "bastion"
    good.options = "ForwardAgent=yes\n\nServerAliveInterval=30\n"
    good.remoteCommand = "tmux attach"
    switch SSHConfig.append(good, configPath: path) {
    case .failure(let why):
        return fail("a valid connection was refused: \(why.summary)")
    case .success(let saved) where saved != "prod":
        return fail("saved under \(saved), expected prod")
    case .success:
        break
    }

    guard let written = try? String(contentsOfFile: path, encoding: .utf8) else {
        return fail("the config vanished")
    }
    // APPEND, not rewrite: every original byte still leads the file.
    if !written.hasPrefix(existing) {
        return fail("the existing config was rewritten rather than appended to")
    }
    // The unterminated last line must not have been joined onto the new block.
    if written.contains("User firstHost") || written.contains("first# added") {
        return fail("the new block was joined onto the previous unterminated line")
    }
    for expected in [
        "Host prod", "HostName prod.example.net", "User user", "Port 2222",
        "IdentityFile ~/.ssh/id_prod", "ProxyJump bastion", "ForwardAgent yes",
        "ServerAliveInterval 30", "RemoteCommand tmux attach", "RequestTTY yes",
    ] where !written.contains(expected) {
        return fail("the written block is missing \(expected)")
    }

    // Round trip: the parser must see what the writer wrote, or the two halves of this
    // feature disagree and the saved host never appears in the `+` menu.
    let hosts = SSHConfig.hosts(configPath: path)
    guard let prod = hosts.first(where: { $0.alias == "prod" }),
        prod.hostName == "prod.example.net", prod.user == "user", prod.port == 2222
    else { return fail("the writer's own output did not survive the reader") }
    if hosts.count != 2 {
        return fail("expected 2 hosts after the append, got \(hosts.count)")
    }

    // A fresh file must be created 0600. Created world-readable, this surfaces much later
    // as ssh refusing a key, with an error that names the key and not the directory.
    let fresh = root + "/fresh/config"
    guard case .success = SSHConfig.append(good, configPath: fresh) else {
        return fail("could not create a config that did not exist")
    }
    let mode = (try? FileManager.default.attributesOfItem(atPath: fresh)[.posixPermissions])
    if (mode as? NSNumber)?.intValue != 0o600 {
        return fail("a freshly created config is mode \(mode ?? "unknown"), expected 0600")
    }

    // The dialled path, which shares nothing with the written path: argv, so a path with a
    // space in it stays one argument instead of being word-split by a shell.
    var spaced = SSHConnection()
    spaced.hostName = "box"
    spaced.user = "user"
    spaced.identityFile = "/tmp/my key"
    spaced.port = "2200"
    if spaced.arguments != ["ssh", "-p", "2200", "-i", "/tmp/my key", "user@box"] {
        return fail("argv was \(spaced.arguments)")
    }

    // THE SHELL INJECTION CASE, and it is the most dangerous assertion in this file.
    //
    // The host runs the command string through `/bin/sh -c`, so a host or alias carrying a
    // semicolon is TWO commands. No validator above rejects a semicolon and none should -
    // the fix belongs at the spawn boundary, where every word is quoted, and this is the
    // check that the fix is actually there. Single quotes make everything inside literal,
    // so the payload must survive as ONE word with its metacharacters inert.
    var evil = SSHConnection()
    evil.hostName = "box.example.net"
    evil.alias = "gone"
    let payloads = [
        "box; touch /tmp/termisu-pwned", "box$(touch /tmp/termisu-pwned)",
        "box`touch /tmp/termisu-pwned`", "box | sh", "it's a box",
    ]
    for payload in payloads {
        let line = SSHConnection.shellQuoted(["ssh", payload])
        // Everything after `ssh ` must be inside one quoted run. The proof is that the
        // dangerous character is never outside quotes: count quote marks and require the
        // payload's metacharacters to sit between an odd and an even one.
        guard line.hasPrefix("'ssh' '") , line.hasSuffix("'") else {
            return fail("quoting produced \(line)")
        }
        for metacharacter in [";", "$", "`", "|"] where payload.contains(metacharacter) {
            // A quoted word cannot contain an unescaped quote, so splitting on `'\''`
            // boundaries is unnecessary: the only way a metacharacter escapes is if the
            // quoting was dropped entirely, which the prefix check above already denies.
            if line.contains("' \(metacharacter)") || line.contains("\(metacharacter) '") {
                return fail("\(metacharacter) escaped the quoting in \(line)")
            }
        }
    }
    // And the apostrophe case, which is the one quoting scheme's own failure mode.
    if SSHConnection.shellQuoted(["it's"]) != "'it'\\''s'" {
        return fail("an apostrophe broke the quoting: \(SSHConnection.shellQuoted(["it's"]))")
    }
    // Round trip through a real shell. Nothing else here proves the quoting works against
    // the thing that actually parses it, and `/bin/sh` is the oracle that can say NO.
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/bin/sh")
    probe.arguments = ["-c", "printf '%s\\n' " + SSHConnection.shellQuoted(payloads)]
    let pipe = Pipe()
    probe.standardOutput = pipe
    do {
        try probe.run()
        let out = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        probe.waitUntilExit()
        let words = out.split(separator: "\n").map(String.init)
        if words != payloads {
            return fail("/bin/sh re-split the quoted words into \(words)")
        }
    } catch {
        return fail("could not run the shell oracle: \(error)")
    }
    if FileManager.default.fileExists(atPath: "/tmp/termisu-pwned") {
        try? FileManager.default.removeItem(atPath: "/tmp/termisu-pwned")
        return fail("a payload EXECUTED -- the quoting is not reaching the spawn boundary")
    }

    // The form's field mapping, driven through the real view. A gate that built its own
    // SSHConnection would pass while the Port field was wired to the User label.
    let form = SSHConnectForm()
    form.fill(good)
    let readBack = form.connection
    if readBack.hostName != good.hostName || readBack.user != good.user
        || readBack.port != good.port || readBack.identityFile != good.identityFile
        || readBack.proxyJump != good.proxyJump || readBack.alias != good.alias
        || readBack.remoteCommand != good.remoteCommand
        || readBack.optionList != good.optionList
    {
        return fail("the form did not read back what was written into it: \(readBack)")
    }

    print(
        "SSH WRITE SMOKE OK: shell injection quoted inert and confirmed by /bin/sh itself,"
            + " newline injection refused in 5 fields, duplicate alias"
            + " refused, refusals left the file byte-identical, the append preserved every"
            + " existing byte and did not join the unterminated last line, the writer's"
            + " output round-tripped through the reader, a fresh config is 0600, and a"
            + " spaced identity path stayed one argv word")
    return 0
}

/// `--smoke-ssh-layout`: the connection dialog's GEOMETRY, with no window shown.
///
/// This exists because the form shipped in v0.28.0 looking broken and nothing could tell.
/// Two controls in it had collapsed to slivers and the whole dialog stood 590pt tall over
/// an 816x510 window, and every gate was green, because the gates drive `Session` and stop
/// at the AppKit layer. A screenshot found it. A screenshot is not a gate.
///
/// The two failures it guards are the two that happened, and both are silent:
///
/// 1. **A control with no intrinsic width collapses inside `NSGridView`.** An `NSTextField`
///    is stretched by a fixed column width; an `NSScrollView` or an `NSStackView` is not,
///    because they report `noIntrinsicMetric` and the default placement is leading. The
///    result is a field that renders as a 30pt stub next to a correct-looking label, and
///    nothing in the layout is an error.
/// 2. **A dialog taller than the window it belongs to.** There is no clamp anywhere in
///    AppKit for this; the panel simply hangs off the window and reads as a leak.
///
/// It walks the real view tree rather than asking the form what it built, so a field
/// renamed, re-parented or dropped is visible to it. The COUNTS are the control: an
/// assertion about widths alone passes a dialog that lost half its fields.
func runSSHLayoutSmoke() -> Int32 {
    func fail(_ why: String) -> Int32 {
        FileHandle.standardError.write(Data("ssh layout smoke: \(why)\n".utf8))
        return 1
    }

    // AppKit refuses to lay out a view tree without an application object, and a
    // `.prohibited` policy keeps this off the Dock and out of the operator's way.
    let probeApp = NSApplication.shared
    probeApp.setActivationPolicy(.prohibited)

    func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    // The CONTAINER's tree, never the bare form. The form measured on its own reports
    // every field at 320pt in the exact build that shipped two collapsed controls, so an
    // oracle rooted at the form is a check placed before the thing it guards.
    let (dialogSize, root) = SSHConnect.measureDialog()
    let inside = descendants(of: root)

    // An editable NSTextField is an input; the labels in column 0 are not, and neither is
    // the placeholder cell AppKit parks inside a scroll view.
    let inputs = inside.compactMap { $0 as? NSTextField }.filter { $0.isEditable }
    let scrollers = inside.compactMap { $0 as? NSScrollView }
    let buttons = inside.compactMap { $0 as? NSButton }

    guard inputs.count == 7 else {
        return fail("expected 7 editable fields, found \(inputs.count) -- the width"
            + " assertions below are vacuous on a form that lost fields")
    }
    guard scrollers.count == 1 else {
        return fail("expected 1 scroll view for Options, found \(scrollers.count)")
    }
    // Found by title rather than by count, because the container contributes its own
    // action buttons to this tree. Their presence is asserted too: a dialog measured
    // without its buttons is measured too short, which is the direction that hides a leak.
    guard let choose = buttons.first(where: { $0.title.hasPrefix("Choose") }) else {
        return fail("the Choose... button is not in the dialog's view tree")
    }
    for title in ["Save & Connect", "Connect", "Cancel"] where
        !buttons.contains(where: { $0.title == title })
    {
        return fail("the dialog has no \(title) button -- its height is being measured"
            + " without the button row")
    }
    // Exactly one Return and exactly one Escape. Zero means a dialog the keyboard cannot
    // finish; two means Return fires whichever button AppKit reaches first, which is a
    // coin flip between saving to the operator's ssh config and not.
    let byReturn = buttons.filter { $0.keyEquivalent == "\r" }
    let byEscape = buttons.filter { $0.keyEquivalent == "\u{1b}" }
    guard byReturn.count == 1, byReturn[0].title == "Save & Connect" else {
        return fail("Return maps to \(byReturn.map(\.title)), expected exactly"
            + " [Save & Connect]")
    }
    guard byEscape.count == 1, byEscape[0].title == "Cancel" else {
        return fail("Escape maps to \(byEscape.map(\.title)), expected exactly [Cancel]")
    }
    // Asserted as a property, not read off a screenshot. macOS dims accent colour in a
    // window that is not key, and the capture mode's window never is (making it key would
    // mean activating the app over whatever the operator is using). So the picture cannot
    // answer "is the primary action marked" and this can.
    guard byReturn[0].bezelColor != nil else {
        return fail("the primary action carries no bezel tint -- all three buttons render"
            + " identically and nothing marks which one Return performs")
    }

    // Every check below runs, and they are reported together. A gate that returns on the
    // first geometry failure costs one full build per defect, and these arrive in groups:
    // the two collapsed controls here had one cause and would have taken two rounds.
    var faults: [String] = []

    // The measurements themselves, always, pass or fail. A geometry gate that prints only
    // a verdict makes the next person re-instrument it to learn anything, and the numbers
    // are the part worth reading.
    for (index, field) in inputs.enumerated() {
        print(String(
            format: "  field[%d] %4dx%-3d", index,
            Int(field.frame.width), Int(field.frame.height)))
    }
    print(String(
        format: "  options  %4dx%-3d   choose %4dx%-3d",
        Int(scrollers[0].frame.width), Int(scrollers[0].frame.height),
        Int(choose.frame.width), Int(choose.frame.height)))
    print(String(
        format: "  dialog   %4dx%-3d", Int(dialogSize.width), Int(dialogSize.height)))

    // 150pt is not a taste threshold. It is well below any laid-out field in a 320pt
    // column and well above the ~30pt stub a collapsed control produces, so it separates
    // the two states and says nothing about the ones in between.
    let floor: CGFloat = 150
    for field in inputs where field.frame.width < floor {
        faults.append("an editable field is \(Int(field.frame.width))pt wide, under"
            + " \(Int(floor))pt -- a control with no intrinsic width collapsed in the grid")
    }
    if scrollers[0].frame.width < floor {
        faults.append("the Options field is \(Int(scrollers[0].frame.width))pt wide, under"
            + " \(Int(floor))pt -- NSScrollView reports no intrinsic width and the grid"
            + " left it at its stub size")
    }
    if scrollers[0].frame.height < 40 {
        faults.append("the Options field is \(Int(scrollers[0].frame.height))pt tall")
    }
    if choose.frame.width < 60 {
        faults.append("the Choose... button is \(Int(choose.frame.width))pt wide")
    }

    // The leak. 460 is derived, not chosen: the smallest window this host will open is
    // 510pt tall (the 120pt pane floor plus chrome at the sizes `--smoke-chrome` covers),
    // and a dialog must sit inside its own window with room for the title bar.
    let ceiling: CGFloat = 460
    let size = dialogSize
    if size.height > ceiling {
        faults.append("the dialog stands \(Int(size.height))pt tall, over the"
            + " \(Int(ceiling))pt ceiling -- it hangs off the bottom of the window it"
            + " belongs to")
    }
    if size.width > 620 {
        faults.append("the dialog is \(Int(size.width))pt wide, over 620pt")
    }

    guard faults.isEmpty else {
        return fail("\(faults.count) fault(s)\n  - " + faults.joined(separator: "\n  - "))
    }

    print(
        "SSH LAYOUT SMOKE OK: 7 fields, the Options box and the Choose button all laid out"
            + " above the collapse floor, dialog \(Int(size.width))x\(Int(size.height))pt"
            + " inside the \(Int(ceiling))pt ceiling")
    return 0
}

/// `--shot-ssh-dialog <path>`: renders the connection dialog to a PNG and exits.
///
/// Not a gate. It is the reason the gate above exists at all: the v0.28.0 form was proven
/// by five green gates and was visibly broken, and the only thing that found it was
/// looking at a screenshot of the operator's screen. This makes that loop available
/// without a window, without his screen, and without raising anything.
///
/// `--smoke-ssh-layout` answers "is any control collapsed"; this answers "does it look
/// right", which is a different question and not one an assertion can hold.
func runSSHDialogShot(_ path: String, dark: Bool) -> Int32 {
    let probeApp = NSApplication.shared
    // `.accessory`, never `.prohibited`: a prohibited app's windows are not composited, so
    // the capture below comes back empty or partial. No Dock icon either way.
    probeApp.setActivationPolicy(.accessory)
    probeApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

    let dialog = SSHConnectDialog()
    dialog.layoutSubtreeIfNeeded()

    // A REAL window, captured by `captureWindow`. `cacheDisplay` and
    // `dataWithPDF` both silently drop layer-backed controls: the first attempt at this
    // produced an image with the seven text fields and NOTHING else - no labels, no
    // buttons, no title - which is a picture that would have sent the next session
    // hunting a layout bug that does not exist. The window server's own composite is the
    // only capture that shows what the operator would see.
    let host = SSHConnect.makeSheet(dialog)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    return captureWindow(host, to: path)
}

/// Writes one window, as the window server composites it, to a PNG.
///
/// `CGWindowListCreateImage` did this in-process until the deployment target went to
/// macOS 26 (2026-10-02, for the SwiftUI glass), where it is unavailable. `screencapture -l`
/// is the system's own window capture and needs no new framework; ScreenCaptureKit would
/// have meant an async content query for a window this process already owns.
///
/// The window goes ON a display, at the bottom of the window stack. `screencapture -l` has
/// nothing to read from a window parked off every display (the old -8000 trick), and
/// ordering it to the back is what keeps the capture from flashing over the operator's work:
/// a window under others is still composited, so it still captures whole.
func captureWindow(_ window: NSWindow, to path: String) -> Int32 {
    if let screen = NSScreen.main { window.setFrameOrigin(screen.visibleFrame.origin) }
    window.orderBack(nil)
    window.displayIfNeeded()
    // The window server needs a turn of the loop before the surface holds anything.
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    // -o drops the window's shadow, -x the shutter sound.
    capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", path]
    do {
        try capture.run()
    } catch {
        FileHandle.standardError.write(Data("could not run screencapture: \(error)\n".utf8))
        return 1
    }
    capture.waitUntilExit()
    guard capture.terminationStatus == 0, let image = NSImage(contentsOfFile: path),
        let rep = image.representations.first, rep.pixelsWide > 1
    else {
        FileHandle.standardError.write(Data("screencapture returned no image for \(path)\n".utf8))
        return 1
    }
    print("wrote \(path) at \(rep.pixelsWide)x\(rep.pixelsHigh)")
    return 0
}

/// `--shot-tabs <path>`: renders the tab island to one PNG and exits.
///
/// The chrome gate answers "does the island fit", which is not the question "does it look
/// right". Three bands, stacked: five tabs at their natural size, ten squeezed to fit, and
/// twenty past the squeeze floor, scrolled to the active tab with the fade showing the
/// overflow.
func runTabsShot(_ path: String) -> Int32 {
    let probeApp = NSApplication.shared
    // `.accessory`, never `.prohibited`: a prohibited app's windows are not composited, so
    // the capture below comes back empty. Learned by --shot-ssh-dialog, not re-learned.
    probeApp.setActivationPolicy(.accessory)
    probeApp.appearance = NSAppearance(named: .darkAqua)

    let few = [
        TabItem(id: 1, title: "\u{2387} termisu", detail: "feat/tab-island · ~/termisu", state: .working),
        TabItem(id: 2, title: "claude 2", detail: "main · ~/bug-brawl", state: .attention),
        TabItem(id: 3, title: "zsh 3", detail: "main · ~/curlbus", state: .error),
        TabItem(id: 4, title: "zsh 4", detail: "", state: .done),
        TabItem(id: 5, title: "~", detail: "", state: .idle),
    ]
    let many = (1...14).map { index in
        TabItem(
            id: index, title: index % 3 == 0 ? "claude \(index)" : "zsh \(index)", detail: "",
            state: [.idle, .working, .done, .error][index % 4])
    }
    let width: CGFloat = 900
    let band = TabMetrics.bandHeight
    // A plausible terminal ground rather than the fallback: the band IS the terminal's own
    // colour in the app, and a shot on any other ground is a case the operator never sees.
    let ground = NSColor(srgbRed: 0x0D / 255, green: 0x0D / 255, blue: 0x0D / 255, alpha: 1)
    // Ten tabs squeeze to fit; twenty hit the floor and scroll, with the active one (15)
    // scrolled into view and the fade on the side that has more.
    let squeezed = Array(many.prefix(10))
    let crowd = (1...20).map { index in
        TabItem(id: index, title: "zsh \(index)", detail: "", state: index == 15 ? .working : .idle)
    }
    let rows: [([TabItem], Int)] = [(few, 0), (squeezed, 5), (crowd, 14)]
    let height = band * CGFloat(rows.count)
    let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    for (row, (items, active)) in rows.enumerated() {
        let model = TabModel()
        model.update(items: items, active: active)
        let host = TabIslandHost(rootView: TabIsland(model: model))
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.clipsToBounds = true
        let slot = NSRect(x: 0, y: height - band * CGFloat(row + 1), width: width, height: band)
        // The same loop the app runs: SwiftUI measures the strip, the frame follows.
        model.onIdealWidthChange = { [weak host, weak model] in
            guard let host, let model else { return }
            host.frame = TabMetrics.islandFrame(band: slot, leading: 92, ideal: model.idealWidth)
        }
        host.frame = TabMetrics.islandFrame(band: slot, leading: 92, ideal: 1)
        content.addSubview(host)
    }

    let host = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.borderless], backing: .buffered, defer: false)
    host.isOpaque = false
    host.backgroundColor = ground
    host.contentView = content
    // `cacheDisplay` and `dataWithPDF` both silently drop layer-backed views, and glass is
    // drawn by the window server; its own composite is the only capture that shows it.
    return captureWindow(host, to: path)
}

/// `--shot-file-panel <png> --shot-root <dir> --shot-open <path>`: the file panel as it
/// paints, for review, with nothing raised or focused.
///
/// The smokes prove the panel from `viewerState`, because a never-shown window gets no
/// requestAnimationFrame and Monaco draws no rows there (P0). A picture needs frames, so
/// this window IS on screen, at alpha 0 and click-through: the compositor runs its
/// frames, nobody sees it and no click lands on it. The image comes
/// from WKWebView's own snapshot, which renders the page regardless of the window's alpha.
func runFilePanelShot(
    _ path: String, webDir: String?, root: String, open file: String, line: Int?
) -> Int32 {
    func fail(_ why: String) -> Int32 {
        FileHandle.standardError.write(Data("file panel shot: \(why)\n".utf8))
        return 1
    }
    let probeApp = NSApplication.shared
    probeApp.setActivationPolicy(.prohibited)
    guard let url = WebPanel.documentURL(override: webDir),
        let panel = WebPanel(documentURL: url, runsWhenHidden: true)
    else {
        return fail("panel document not found; build web/ or pass --web-dir")
    }
    let size = NSSize(width: 1080, height: 700)
    let window = NSWindow(
        contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.frame = NSRect(origin: .zero, size: size)
    window.contentView = panel
    // Front, not back: a window every other window covers is occluded, and WebKit stops
    // frames for an occluded window just as for a hidden one. At alpha 0, click-through,
    // in an app that cannot activate, "front" is invisible and takes no focus.
    window.orderFrontRegardless()

    var shown: ViewerState?
    var errors: [String] = []
    panel.onProtocolError = { errors.append($0) }
    panel.onMessage = { message in
        switch message {
        case .ready:
            panel.post(
                .initialize(
                    theme: PanelTheme(
                        background: "#16151b", foreground: "#e6e6e6", accent: "#5865f2",
                        dim: "#8b8b96"),
                    panel: .files))
            panel.post(.tree(root: root, error: nil))
            if case .success(let listing) = FileAccess.list(
                root: root, relative: "", ignoredNames: Git.ignoredNames)
            {
                panel.post(.directory(path: "", entries: listing.entries, error: nil))
            }
            panel.post(.select(path: file, line: line))
        case .listDirectory(let directory):
            if case .success(let listing) = FileAccess.list(
                root: root, relative: directory, ignoredNames: Git.ignoredNames)
            {
                panel.post(.directory(path: directory, entries: listing.entries, error: nil))
            }
        case .openFile(let requested):
            switch FileAccess.read(root: root, relative: requested) {
            case .success(let text): panel.post(.fileContent(path: requested, text: text, error: nil))
            case .failure(let reason):
                panel.post(.fileContent(path: requested, text: "", error: reason.description))
            }
        case .viewerState(let state):
            if state.path == file { shown = state }
        default:
            break
        }
    }

    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline, shown == nil {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    guard shown != nil else {
        return fail("\(file) never reported a viewerState. errors=\(errors)")
    }
    // The report fires when the model is set; the rows paint on the frames after it.
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))

    // What painted, asked of the document rather than guessed from the picture: frames
    // counted over a quarter second, Monaco's rendered rows, and the editor background.
    var painted: String?
    panel.inspect(
        """
        // Loaded on demand here, because a font nothing has used yet reads "unloaded"
        // whether or not the CSP would let it in.
        const codicon = await document.fonts.load('16px codicon').then(
          (faces) => faces.length + ' codicon face(s) loaded', (error) => 'codicon failed: ' + error);
        return await new Promise((done) => { let n = 0; const tick = () => { n += 1; requestAnimationFrame(tick); };
          requestAnimationFrame(tick);
          setTimeout(() => { const bg = document.querySelector('.monaco-editor-background');
            done(JSON.stringify({ frames: n, rows: document.querySelectorAll('.view-line').length,
              editors: document.querySelectorAll('.monaco-editor').length,
              markdownBlocks: [...document.querySelectorAll('.markdown > *')].map((e) => e.tagName + ':' + (e.getAttribute('dir') ?? '-') + ':' + getComputedStyle(e).direction).join(' '),
              fonts: [...document.fonts].map((f) => f.family + ':' + f.status).join(' ') + ' / ' + codicon,
              colours: new Set([...document.querySelectorAll('.view-line span[class*="mtk"]')].map((e) => e.className)).size,
              background: bg ? getComputedStyle(bg).backgroundColor : null,
              visibility: document.visibilityState, w: innerWidth, h: innerHeight })); }, 250); })
        """
    ) { result in
        switch result {
        case .success(let value): painted = (value as? String) ?? "a non-string answer"
        case .failure(let error): painted = "inspect failed: \(error)"
        }
    }
    let inspectDeadline = Date().addingTimeInterval(5)
    while Date() < inspectDeadline, painted == nil {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    print("painted: \(painted ?? "no answer")")

    var written: Int32?
    panel.snapshot { image, error in
        guard let image, let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else {
            written = fail("WebKit returned no snapshot: \(error.map { "\($0)" } ?? "no error given")")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path) (\(file): \(shown.map { "\($0.language), \($0.tokenizedLines) coloured" } ?? "?"))")
            written = 0
        } catch {
            written = fail("could not write \(path): \(error)")
        }
    }
    let snapDeadline = Date().addingTimeInterval(10)
    while Date() < snapDeadline, written == nil {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    window.orderOut(nil)
    return written ?? fail("the snapshot never completed")
}

/// `--smoke-split`: the split tiling arithmetic, with no window and no pty.
///
/// The chrome gate already paid for this lesson once: a sidebar computed as a CONSTANT
/// (`x = width - 260`) tiles perfectly at 1120 and overlaps the pane at 300, so a gate that
/// only tests a comfortable window passes the wrong implementation. Splits have the same
/// shape with more places to put it, so the odd and narrow sizes are the whole point.
///
/// Three assertions that exact tiling CANNOT make on its own, and each guards a defect that
/// tiles perfectly while being wrong:
///
/// - **Order.** A vertical split with `first` at the bottom tiles exactly. AppKit's origin
///   is bottom-left, so the top pane is the HIGH y, and getting it backwards puts a new
///   split above the pane it was made from.
/// - **Divider indices.** The walk emits a branch's divider before descending; if
///   `adjusting(dividerAt:)` counted the other way, a drag would resize a different
///   divider than the one under the pointer, and both orders tile.
/// - **Focus geometry.** A tree walk finds a sibling that is correct by the data structure
///   and nowhere near the arrow that was pressed.
///
/// Mutants, measured 2026-08-14: five run, four killed, **one survivor recorded**.
/// Removing the `overlap > 0` FILTER from `neighbor` changes no answer this layout can
/// produce, because `overlap` is also the tie-break and every candidate at the minimum
/// distance in a guillotine tiling shares the same boundary. No case built here kills it
/// and none was faked to look like it did. The filter stays as defence for a layout that
/// is not a guillotine tiling; it is NOT evidence, and this note is the point.
func runSplitSmoke() -> Int32 {
    func fail(_ why: String) -> Int32 {
        FileHandle.standardError.write(Data("split smoke: \(why)\n".utf8))
        return 1
    }

    /// Every pane accounted for, nothing overlapping, nothing outside, and every point of
    /// the rect either in a pane or in a divider. The last clause is what catches a seam:
    /// area alone is satisfied by a tiling that loses a column here and gains one there.
    func tilesExactly(_ tree: SplitTree, _ rect: NSRect) -> String? {
        let panes = SplitLayout.tile(tree, in: rect)
        let dividers = SplitLayout.dividers(tree, in: rect)
        guard panes.count == tree.leaves.count else {
            return "expected \(tree.leaves.count) panes, got \(panes.count)"
        }
        for pane in panes {
            if pane.rect.width < 0 || pane.rect.height < 0 {
                return "pane \(pane.id) has a negative side: \(pane.rect)"
            }
            if !NSContainsRect(NSIntegralRect(rect), pane.rect), !pane.rect.isEmpty {
                return "pane \(pane.id) at \(pane.rect) escapes \(rect)"
            }
        }
        for (a, b) in pairs(panes) where NSIntersectsRect(a.rect, b.rect) {
            return "panes \(a.id) and \(b.id) OVERLAP: \(a.rect) vs \(b.rect)"
        }
        // Point coverage on a lattice, not an area sum. Every integer point of the rect
        // belongs to exactly one pane or to a divider.
        let whole = NSIntegralRect(rect)
        var x = whole.minX
        while x < whole.maxX {
            var y = whole.minY
            while y < whole.maxY {
                let point = NSPoint(x: x + 0.5, y: y + 0.5)
                let inPane = panes.filter { NSPointInRect(point, $0.rect) }.count
                let inDivider = dividers.filter { NSPointInRect(point, $0.rect) }.count
                if inPane + inDivider != 1 {
                    return "point \(point) is covered \(inPane + inDivider) times"
                }
                y += 1
            }
            x += 1
        }
        return nil
    }

    func pairs(_ panes: [SplitPane]) -> [(SplitPane, SplitPane)] {
        var out: [(SplitPane, SplitPane)] = []
        for i in panes.indices {
            for j in panes.indices where j > i { out.append((panes[i], panes[j])) }
        }
        return out
    }

    // A single leaf takes everything. The CONTROL: without it, "tiles exactly" is also
    // satisfied by an implementation that subtracts a divider it never drew.
    let alone = SplitLayout.tile(.leaf(1), in: NSRect(x: 0, y: 0, width: 801, height: 457))
    guard alone.count == 1, alone[0].rect == NSRect(x: 0, y: 0, width: 801, height: 457)
    else {
        return fail("one pane must take the whole rect, got \(alone)")
    }
    guard SplitLayout.dividers(.leaf(1), in: NSRect(x: 0, y: 0, width: 801, height: 457))
        .isEmpty
    else {
        return fail("a single pane must have no dividers")
    }

    // Four trees, ten sizes each, deliberately odd and deliberately narrow. 61x37 cannot
    // hold four panes at any sane floor, and that is the case that has to stay exact.
    let deep = SplitTree.branch(
        axis: .horizontal, fraction: 0.5,
        first: .branch(axis: .vertical, fraction: 0.5, first: .leaf(1), second: .leaf(2)),
        second: .branch(
            axis: .vertical, fraction: 0.33,
            first: .leaf(3),
            second: .branch(
                axis: .horizontal, fraction: 0.5, first: .leaf(4), second: .leaf(5))))
    let trees: [(String, SplitTree)] = [
        ("one", .leaf(1)),
        ("side by side", .branch(
            axis: .horizontal, fraction: 0.5, first: .leaf(1), second: .leaf(2))),
        ("stacked", .branch(
            axis: .vertical, fraction: 0.5, first: .leaf(1), second: .leaf(2))),
        ("five deep", deep),
    ]
    let sizes: [NSSize] = [
        NSSize(width: 1120, height: 700), NSSize(width: 801, height: 457),
        NSSize(width: 300, height: 200), NSSize(width: 137, height: 99),
        NSSize(width: 61, height: 37), NSSize(width: 13, height: 9),
        NSSize(width: 7, height: 5), NSSize(width: 1, height: 1),
        NSSize(width: 0, height: 0), NSSize(width: 240, height: 61),
    ]
    // Fractional origins and sizes, because a real content rect is one. Without these the
    // integralisation is never exercised: every size above is already whole, so removing
    // `NSIntegralRect` changes nothing and the gate cannot see it. Measured 2026-08-14 -
    // that mutant survived the first version of this gate.
    let awkward: [NSRect] = [
        NSRect(x: 0.5, y: 0.25, width: 800.7, height: 456.3),
        NSRect(x: 0, y: 0, width: 137.5, height: 99.5),
        NSRect(x: 2.75, y: 1.1, width: 61.4, height: 37.9),
    ]
    var checked = 0
    for (name, tree) in trees {
        for rect in awkward {
            if let why = tilesExactly(tree, rect) {
                return fail("\(name) at fractional \(rect): \(why)")
            }
            checked += 1
        }
        for size in sizes {
            let rect = NSRect(x: 0, y: 0, width: size.width, height: size.height)
            if let why = tilesExactly(tree, rect) {
                return fail("\(name) at \(Int(size.width))x\(Int(size.height)): \(why)")
            }
            checked += 1
        }
    }

    // ORDER. `first` is the top pane, and the top pane is the high y.
    let stacked = SplitLayout.tile(
        .branch(axis: .vertical, fraction: 0.5, first: .leaf(1), second: .leaf(2)),
        in: NSRect(x: 0, y: 0, width: 400, height: 300))
    guard let top = stacked.first(where: { $0.id == 1 }),
        let bottom = stacked.first(where: { $0.id == 2 }), top.rect.minY > bottom.rect.minY
    else {
        return fail("in a vertical split the FIRST pane must sit above the second, got"
            + " \(stacked)")
    }
    // And left is left.
    let beside = SplitLayout.tile(
        .branch(axis: .horizontal, fraction: 0.5, first: .leaf(1), second: .leaf(2)),
        in: NSRect(x: 0, y: 0, width: 400, height: 300))
    guard let left = beside.first(where: { $0.id == 1 }),
        let right = beside.first(where: { $0.id == 2 }), left.rect.minX < right.rect.minX
    else {
        return fail("in a horizontal split the FIRST pane must sit left of the second")
    }

    // DIVIDER INDEX. Adjusting divider 0 of the five-pane tree must move the outer
    // boundary and nothing else. Both index orders tile, so only this can tell them apart.
    let frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
    let baseline = SplitLayout.tile(deep, in: frame)
    let nudged = SplitLayout.tile(deep.adjusting(dividerAt: 0, to: 0.8), in: frame)
    guard let wideLeft = nudged.first(where: { $0.id == 1 }),
        let baseLeft = baseline.first(where: { $0.id == 1 }),
        wideLeft.rect.width > baseLeft.rect.width
    else {
        return fail("adjusting divider 0 did not widen the left half -- the walk and"
            + " adjusting() disagree about which divider is which")
    }
    if let why = tilesExactly(deep.adjusting(dividerAt: 0, to: 0.8), frame) {
        return fail("an adjusted tree stopped tiling: \(why)")
    }

    // FOCUS. From pane 1 (top left), right must reach the right half and down must reach
    // pane 2 directly below - never pane 3, which is correct by the tree and wrong by eye.
    guard SplitLayout.neighbor(of: 1, among: baseline, axis: .vertical, forward: true) == 2
    else {
        return fail("down from pane 1 must land on pane 2, got"
            + " \(String(describing: SplitLayout.neighbor(of: 1, among: baseline, axis: .vertical, forward: true)))")
    }
    guard SplitLayout.neighbor(of: 1, among: baseline, axis: .horizontal, forward: true) == 3
    else {
        return fail("right from pane 1 must land on pane 3, got"
            + " \(String(describing: SplitLayout.neighbor(of: 1, among: baseline, axis: .horizontal, forward: true)))")
    }
    // The control: there is nothing left of the left column, and a mover that returns
    // *something* there would wrap focus around the screen.
    guard SplitLayout.neighbor(of: 1, among: baseline, axis: .horizontal, forward: false)
        == nil
    else {
        return fail("there is nothing to the left of pane 1")
    }

    // TREE EDITS. Splitting adds exactly one leaf and keeps the rest; removing collapses
    // the branch so the survivor takes the whole rectangle rather than keeping a divider
    // with nothing on the far side.
    guard let split = SplitTree.leaf(1).splitting(1, with: 2, axis: .horizontal),
        split.leaves == [1, 2]
    else {
        return fail("splitting a lone leaf must give two leaves in order")
    }
    guard SplitTree.leaf(1).splitting(99, with: 2, axis: .horizontal) == nil else {
        return fail("splitting an absent pane must refuse, not silently no-op")
    }
    guard let pruned = deep.removing(4), pruned.leaves == [1, 2, 3, 5] else {
        return fail("removing pane 4 must leave [1,2,3,5], got"
            + " \(String(describing: deep.removing(4)?.leaves))")
    }
    guard let collapsed = SplitTree
        .branch(axis: .horizontal, fraction: 0.5, first: .leaf(1), second: .leaf(2))
        .removing(2), collapsed == .leaf(1)
    else {
        return fail("removing one of two panes must COLLAPSE the branch to a bare leaf")
    }
    let survivor = SplitLayout.tile(collapsed, in: frame)
    guard survivor.count == 1, survivor[0].rect == frame else {
        return fail("after a collapse the survivor must take the whole rect, got"
            + " \(survivor)")
    }
    guard SplitTree.leaf(1).removing(1) == nil else {
        return fail("removing the last pane must give an empty tree")
    }

    // The drag floor, and its honest limit: a container that cannot hold two floors
    // reports the middle rather than clamping to a side it cannot satisfy.
    let handle = SplitLayout.dividers(
        .branch(axis: .horizontal, fraction: 0.5, first: .leaf(1), second: .leaf(2)),
        in: frame)[0]
    let dragged = SplitLayout.fraction(for: handle, at: NSPoint(x: 5, y: 300))
    guard dragged * (frame.width - SplitLayout.divider) >= SplitLayout.minimumWidth else {
        return fail("a drag to x=5 must stop at the \(Int(SplitLayout.minimumWidth))pt"
            + " floor, gave fraction \(dragged)")
    }
    let tiny = SplitLayout.dividers(
        .branch(axis: .horizontal, fraction: 0.5, first: .leaf(1), second: .leaf(2)),
        in: NSRect(x: 0, y: 0, width: 100, height: 100))[0]
    guard SplitLayout.fraction(for: tiny, at: NSPoint(x: 1, y: 50)) == 0.5 else {
        return fail("a container too small for two floors must report the middle")
    }

    // PER-PANE GRIDS. The defect this guards is a single shared derivation handing every
    // pane the focused pane's grid: a pty told it is 200 columns wide inside an 80 column
    // pane wraps in the wrong place, silently, and only once a line is long enough.
    // 1600 points of panes plus the divider, so the halves are equal whatever the divider is
    // (it went from 6pt to Ghostty's 1pt; an odd gap cannot split an even width evenly).
    let wide = SplitLayout.tile(
        .branch(axis: .horizontal, fraction: 0.5, first: .leaf(1), second: .leaf(2)),
        in: NSRect(x: 0, y: 0, width: 1600 + SplitLayout.divider, height: 800))
    let grids = wide.map {
        SplitLayout.grid(
            for: $0.rect, cellWidth: 14, cellHeight: 30, scale: 2, padding: 8)
    }
    guard grids.count == 2, grids[0].cols == grids[1].cols else {
        return fail("two equal panes must derive equal grids, got \(grids)")
    }
    let whole = SplitLayout.grid(
        for: NSRect(x: 0, y: 0, width: 1600, height: 800),
        cellWidth: 14, cellHeight: 30, scale: 2, padding: 8)
    guard grids[0].cols < whole.cols else {
        return fail("a half-width pane derived \(grids[0].cols) columns, the same as the"
            + " whole \(whole.cols) -- every pane is being sized from one shared rect")
    }
    // Rows must NOT shrink in a side-by-side split. A derivation that used the wrong axis
    // would still make cols smaller and would still look plausible in a log.
    guard grids[0].rows == whole.rows else {
        return fail("a side-by-side split changed the row count from \(whole.rows) to"
            + " \(grids[0].rows)")
    }
    // The floor: a pane squeezed to nothing still reports a usable grid, because a
    // zero-column pty is a division by zero in the reflow.
    let squeezed = SplitLayout.grid(
        for: NSRect(x: 0, y: 0, width: 1, height: 1), cellWidth: 14, cellHeight: 30,
        scale: 2, padding: 8)
    guard squeezed.cols >= 2, squeezed.rows >= 2 else {
        return fail("a squeezed pane reported \(squeezed), under the 2x2 floor")
    }
    // Control: with no cell metrics yet there is nothing to divide by, and the spawn
    // default is the honest answer rather than a computed 2x2.
    guard SplitLayout.grid(
        for: NSRect(x: 0, y: 0, width: 1600, height: 800), cellWidth: 0, cellHeight: 0,
        scale: 2, padding: 8) == (80, 24)
    else {
        return fail("with no cell metrics the grid must be the 80x24 spawn default")
    }

    // TABS OWN THEIR SPLITS (P2). The maintainer: "כל פיצול פותח טאב, כשאתה עובר בניהם שוב אין פיצול?"
    // A split stays inside its tab, survives a trip to another tab and back with its focus,
    // and the strip counts tabs, not panes.
    var set = TabSet()
    let first = set.open(1)
    set.select(first)
    guard set.split(1, with: 3, axis: .horizontal) else {
        return fail("splitting a pane in its tab was refused")
    }
    set.select(set.open(2))
    set.select(first)
    guard set.tabs.count == 2, set.currentTab?.tree.leaves == [1, 3], set.currentTab?.focused == 3 else {
        return fail("a split did not survive a tab switch: \(set.tabs)")
    }
    let keyed = set.currentTab?.id
    set.focus(1)
    guard set.currentTab?.id == keyed, set.currentTab?.focused == 1 else {
        return fail("moving focus inside a tab changed the tab or lost the focus")
    }
    guard set.remove(3) == .pruned(tab: 0), set.currentTab?.tree == .leaf(1), set.tabs.count == 2 else {
        return fail("closing one pane of a split must leave its tab: \(set.tabs)")
    }
    set.retile(.leaf(9))
    guard set.currentTab?.tree == .leaf(1) else {
        return fail("a retile with other panes was applied")
    }
    // Closing the tab on screen brings the one that slides into its place; the last one,
    // the one before it.
    var row = TabSet()
    for pane in [10, 20, 30] { _ = row.open(pane) }
    row.select(1)
    guard row.remove(20) == .closedTab(was: 1), row.currentTab?.focused == 30 else {
        return fail("closing the middle tab must bring the next one, got \(row.current)")
    }
    guard row.remove(30) == .closedTab(was: 1), row.currentTab?.focused == 10 else {
        return fail("closing the last tab must bring the one before it")
    }
    guard row.remove(10) == .closedTab(was: 0), row.tabs.isEmpty, row.remove(10) == .absent else {
        return fail("closing the only tab must leave none")
    }
    guard WorkStateRule.loudest([.idle, .done, .working]) == .working,
        WorkStateRule.loudest([.error, .attention, .working]) == .attention,
        WorkStateRule.loudest([.done, .error]) == .error,
        WorkStateRule.loudest([]) == .idle
    else {
        return fail("a tab's dot is not its loudest pane")
    }

    print(
        "SPLIT SMOKE OK: \(checked) tree/size combinations tile exactly with no overlap and"
            + " full point coverage down to 0x0, first is top and first is left, divider 0"
            + " moves the outer boundary, focus is geometric with no wrap, a collapse hands"
            + " the whole rect to the survivor, the drag floor holds, and each pane derives"
            + " its OWN grid (\(grids[0].cols)x\(grids[0].rows) per half against"
            + " \(whole.cols)x\(whole.rows) whole); tabs keep their own splits")
    return 0
}

let arguments = CommandLine.arguments
if arguments.contains("--smoke") {
    exit(runSmoke())
}
/// `--smoke-lastpane`: what closing the LAST pane does, as a truth table.
///
/// The behaviour cannot be reached without an app run and a pty, and its wrong answer is
/// the whole window disappearing -- which is why the decision was split out of
/// `closePane` into `LastPaneOutcome` and is asserted here instead of being read.
///
/// BOTH rows matter and neither is redundant. Only the first is what the maintainer asked for; the
/// second is the escape hatch that makes the first safe, and an implementation that
/// respawns unconditionally satisfies the ask completely while leaving the app impossible
/// to quit by typing `exit`.
func runLastPaneSmoke() -> Int32 {
    func fail(_ why: String) -> Int32 {
        FileHandle.standardError.write(Data("lastpane smoke: \(why)\n".utf8))
        return 1
    }
    if LastPaneOutcome.decide(childExited: false) != .respawn {
        return fail("closing the last tab by hand quits the app instead of opening a shell")
    }
    if LastPaneOutcome.decide(childExited: true) != .terminate {
        return fail("a child that exited respawns; `exit` would never quit the app")
    }
    print(
        "LASTPANE SMOKE OK: an operator close of the last pane respawns,"
            + " a child that exited still terminates")
    return 0
}

/// `--smoke-blocks`: the OSC 133 block grouping, with no window and no pty.
///
/// It exists because of what a wrong grouping LOOKS like, which is not "the blocks are
/// wrong". The maintainer reported "a scrollbar on the left even though there is nothing to scroll":
/// the gutter bar of the live block ran from the prompt to the bottom edge of the window,
/// a 3pt grey column down empty rows, and it reads as a scroll thumb rather than as a bar
/// belonging to a command.
///
/// The cause is that a block owned everything from its prompt until the NEXT prompt, and
/// the last block has no next prompt, so it owned every remaining row of the grid whether
/// or not anything had been written there. `output(of:)` already dropped trailing empty
/// rows for the TEXT; the gutter drew the untrimmed range. One fact in two places.
///
/// The clamp is the CURSOR, not row emptiness. Row emptiness would need the text of every
/// row every frame, and the cursor is already in the frame and is exact: the live block
/// cannot extend past where the shell is about to write. Only the block that reaches the
/// end of the grid is clamped -- every other block is bounded by the next prompt and must
/// keep its blank rows, because a command that printed blank lines printed them.
func runBlocksSmoke() -> Int32 {
    func fail(_ why: String) -> Int32 {
        FileHandle.standardError.write(Data("blocks smoke: \(why)\n".utf8))
        return 1
    }

    let out = UInt8(TERMISU_ROW_OUTPUT)
    let prompt = UInt8(TERMISU_ROW_PROMPT)

    // A 12-row grid: prompt, two rows of output, then nine rows nothing ever wrote to.
    // The cursor sits on row 3, the row after the output, which is where the shell is.
    var classes = [UInt8](repeating: out, count: 12)
    classes[0] = prompt
    let live = computeBlocks(classes, cursorRow: 3)
    guard live.count == 1 else { return fail("expected one block, got \(live.count)") }
    guard live[0].rows == 0..<4 else {
        return fail("the live block ran to \(live[0].rows.upperBound) instead of the cursor")
    }

    // THE CONTROL. Without the clamp this is what came out, and it is what drew the bar
    // down the empty rows. If the assertion above ever passes for a build that produces
    // this, the clamp is not what made it pass.
    guard live[0].rows != 0..<12 else {
        return fail("the live block still owns the whole grid")
    }

    // A block that is NOT last keeps every row up to the next prompt, blank ones included:
    // a command that printed blank lines printed them, and trimming would eat its output.
    var two = [UInt8](repeating: out, count: 12)
    two[0] = prompt
    two[6] = prompt
    let blocks = computeBlocks(two, cursorRow: 7)
    guard blocks.count == 2 else { return fail("expected two blocks, got \(blocks.count)") }
    guard blocks[0].rows == 0..<6 else {
        return fail("the earlier block was trimmed to \(blocks[0].rows); only the last may be")
    }
    guard blocks[1].rows == 6..<8 else {
        return fail("the live block is \(blocks[1].rows), expected 6..<8")
    }

    // A prompt with nothing under it yet. The bar must cover the prompt run and stop, not
    // collapse to nothing -- a zero-height bar is a block the operator cannot click.
    var bare = [UInt8](repeating: out, count: 12)
    bare[0] = prompt
    bare[1] = prompt
    let wrapped = computeBlocks(bare, cursorRow: 0)
    guard wrapped.count == 1, wrapped[0].rows == 0..<2 else {
        return fail("a wrapped prompt with the cursor on its first row became \(wrapped)")
    }

    // A cursor past the end of the grid must not widen the range beyond it.
    let overrun = computeBlocks(classes, cursorRow: 99)
    guard overrun[0].rows == 0..<12 else {
        return fail("a cursor past the grid gave \(overrun[0].rows)")
    }

    // No marks at all means no gutter. Without shell integration there is nothing to
    // group, and guessing would put bars over arbitrary scrollback.
    guard computeBlocks([UInt8](repeating: out, count: 12), cursorRow: 4).isEmpty else {
        return fail("unmarked rows produced blocks")
    }

    print(
        "BLOCKS SMOKE OK: the live block stops at the cursor (0..<4 of a 12-row grid), "
            + "an earlier block keeps its blank rows to the next prompt, a wrapped prompt "
            + "keeps its whole run, a cursor past the grid does not widen it, and unmarked "
            + "rows make no blocks at all")
    return 0
}

if arguments.contains("--smoke-split") {
    exit(runSplitSmoke())
}
if arguments.contains("--smoke-lastpane") {
    exit(runLastPaneSmoke())
}
if arguments.contains("--smoke-blocks") {
    exit(runBlocksSmoke())
}
if arguments.contains("--smoke-ssh-layout") {
    exit(runSSHLayoutSmoke())
}
if let index = arguments.firstIndex(of: "--shot-tabs"), index + 1 < arguments.count {
    exit(runTabsShot(arguments[index + 1]))
}
if let index = arguments.firstIndex(of: "--shot-ssh-dialog"), index + 1 < arguments.count {
    exit(runSSHDialogShot(arguments[index + 1], dark: !arguments.contains("--light")))
}
if arguments.contains("--smoke-ssh-write") {
    exit(runSSHWriteSmoke())
}
if arguments.contains("--smoke-workstate") {
    exit(runWorkStateSmoke())
}
if arguments.contains("--smoke-selection") {
    exit(runSelectionSmoke())
}
if arguments.contains("--smoke-offline") {
    exit(runOfflineSmoke())
}
if arguments.contains("--smoke-bell") {
    exit(runBellSmoke())
}
if arguments.contains("--smoke-chrome") {
    exit(runChromeSmoke())
}
if arguments.contains("--smoke-ssh") {
    exit(runSSHSmoke())
}
if arguments.contains("--smoke-agent") {
    exit(runAgentSmoke())
}
if arguments.contains("--smoke-worktree") {
    exit(runWorktreeSmoke())
}
if arguments.contains("--smoke-history") {
    exit(runHistorySmoke())
}
if arguments.contains("--smoke-files") {
    exit(runFilesSmoke())
}

var webDirArgument: String?
if let index = arguments.firstIndex(of: "--web-dir"), index + 1 < arguments.count {
    webDirArgument = arguments[index + 1]
}
if arguments.contains("--smoke-panel") || arguments.contains("--smoke-panel-control") {
    // A WKWebView needs an application object to run its document.
    let probeApp = NSApplication.shared
    probeApp.setActivationPolicy(.prohibited)
    exit(
        runPanelSmoke(
            webDir: webDirArgument, control: arguments.contains("--smoke-panel-control")))
}
if let index = arguments.firstIndex(of: "--shot-file-panel"), index + 1 < arguments.count,
    let rootIndex = arguments.firstIndex(of: "--shot-root"), rootIndex + 1 < arguments.count,
    let openIndex = arguments.firstIndex(of: "--shot-open"), openIndex + 1 < arguments.count
{
    exit(
        runFilePanelShot(
            arguments[index + 1], webDir: webDirArgument, root: arguments[rootIndex + 1],
            open: arguments[openIndex + 1],
            line: arguments.firstIndex(of: "--shot-line").flatMap { at in
                at + 1 < arguments.count ? Int(arguments[at + 1]) : nil
            }))
}
if arguments.contains("--smoke-file-panel") || arguments.contains("--smoke-file-panel-control") {
    let probeApp = NSApplication.shared
    probeApp.setActivationPolicy(.prohibited)
    exit(
        runFilePanelSmoke(
            webDir: webDirArgument, control: arguments.contains("--smoke-file-panel-control")))
}

var command: String?
if let index = arguments.firstIndex(of: "--command"), index + 1 < arguments.count {
    command = arguments[index + 1]
}

// Settings (S1): ~/.ruuah/config.toml, or --config-dir for a capture/test that must not
// touch the real one. Loading never fails into an unusable state; anything that could
// not be honoured arrives as an error string the app shows loudly on launch.
var configDir: String?
if let index = arguments.firstIndex(of: "--config-dir"), index + 1 < arguments.count {
    configDir = arguments[index + 1]
}
var config: OpaquePointer?
if let configDir {
    _ = configDir.withCString { pointer in termisu_config_load(pointer, &config) }
} else {
    _ = termisu_config_load(nil, &config)
}
let configError = termisu_config_error(config).map { String(cString: $0) }

// When the binary runs from an assembled .app (scripts/build-app.sh), the app is
// Hebrew-first: auto base direction unless --ltr. The bare CLI binary keeps the
// flag-driven defaults unchanged. A window opens straight into the login shell --
// no splash, like Ghostty; the bundled banner remains available via --splash.
let bundledBanner = Bundle.main.path(forResource: "banner", ofType: "sh")
if command == nil, arguments.contains("--splash"), let bundledBanner {
    command = "sh '\(bundledBanner)'"
}
// The config's shell is the default for new sessions; explicit CLI intent outranks it.
if command == nil, !arguments.contains("--splash"),
    let shell = termisu_config_shell(config).map({ String(cString: $0) })
{
    command = shell
}
// CLI flags outrank the config, which outranks the bundle default (the .app is
// Hebrew-first; the bare CLI binary defaults LTR).
let autoDirection: Bool
if arguments.contains("--auto-direction") {
    autoDirection = true
} else if arguments.contains("--ltr") {
    autoDirection = false
} else {
    autoDirection = termisu_config_auto_direction(config, bundledBanner != nil)
}
// Logical size; the delegate multiplies by the backing scale at spawn.
let configFontSize = termisu_config_font_size(config)
let baseFontSize: Float = configFontSize > 0 ? configFontSize : 16

// Shell integration (S2): spawned shells inherit this process's environment, so pointing
// ZDOTDIR at the bundled bootstrap is all the wiring blocks need. zsh-only by nature (the
// variable means nothing to other shells), .app-only in practice (the bare CLI binary has
// no resource bundle, and an externally-set ZDOTDIR chain is left alone there).
if let resources = Bundle.main.resourcePath {
    let zdotdir = resources + "/shell/zdotdir"
    let integration = resources + "/shell/termisu-integration.zsh"
    if FileManager.default.fileExists(atPath: zdotdir + "/.zshenv"),
        FileManager.default.fileExists(atPath: integration)
    {
        setenv("TERMISU_INTEGRATION", integration, 1)
        if let original = getenv("ZDOTDIR") {
            setenv("TERMISU_USER_ZDOTDIR", String(cString: original), 1)
        }
        setenv("ZDOTDIR", zdotdir, 1)
    }
    // The bundled `termisu` command (`termisu md README.md`). Appended, not prepended, so a
    // user's own tool of the same name still wins, and set here rather than in the zsh hooks
    // so bash and fish shells get it too. login shells' path_helper keeps entries it does not
    // know, at the end.
    let bin = resources + "/bin"
    if FileManager.default.isExecutableFile(atPath: bin + "/termisu") {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        setenv("PATH", path + ":" + bin, 1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = HostAppDelegate(
    command: command, autoDirection: autoDirection, config: config,
    baseFontSize: baseFontSize, configError: configError, configDir: configDir,
    webDir: webDirArgument)
app.delegate = delegate
app.run()
