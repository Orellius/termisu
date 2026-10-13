// What the file panel may read, and how it reads it.
//
// The panel names files by paths RELATIVE to one root the host chose (the active
// session's repository, or its directory). Every path crosses the bridge from the
// document, so it is validated here, by the side that acts on it, the same rule the diff
// panel applies to `requestDiff`. The policy is a set of free functions over the
// filesystem rather than code inside AppDelegate so `--smoke-files` can reach it with no
// window and no webview, the reason `PanelNavigation` and `WorkStateRule` are shaped
// the same way.
//
// Read only. Nothing here writes, renames or deletes; editing is P5 and a separate
// decision (docs/decisions/2026-09-29-agent-workspace-scope.md).

import Foundation

enum FileAccess {
    /// Larger files are refused with their size rather than shipped across the bridge:
    /// the text travels as one JSON string through evaluateJavaScript, and a viewer
    /// nobody can scroll is not worth the stall.
    static let readLimit = 2 << 20  // 2 MiB
    /// A directory past this is listed up to it, with the rest named in the error.
    static let listLimit = 5000
    /// Bytes inspected for a NUL, the same heuristic git uses to call a file binary.
    private static let binaryProbe = 8192

    struct Entry: Equatable {
        let name: String
        let isDirectory: Bool
        let ignored: Bool

        var json: [String: Any] {
            ["name": name, "isDirectory": isDirectory, "ignored": ignored]
        }
    }

    /// The absolute URL for `relative` under `root`, or why it is refused.
    ///
    /// Refuses an absolute path, a NUL, and anything whose RESOLVED location is outside
    /// the resolved root: `..` segments and symlinks are both ways out, and resolving
    /// both sides before comparing closes the two at once. Resolving only the request
    /// would let a root that is itself behind a symlink (`/tmp` is `/private/tmp` on
    /// this machine) refuse everything, which is the fail-closed bug `PanelNavigation`
    /// already hit once.
    static func resolve(root: String, relative: String) -> Result<URL, PanelFailure> {
        if relative.hasPrefix("/") {
            return .failure(PanelFailure("absolute paths are not accepted: \(relative)"))
        }
        if relative.contains("\u{0}") {
            return .failure(PanelFailure("path contains a NUL"))
        }
        let base = URL(fileURLWithPath: root, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let target = (relative.isEmpty ? base : base.appendingPathComponent(relative))
            .standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let basePath = base.path
        guard target.path == basePath || target.path.hasPrefix(basePath + "/") else {
            return .failure(PanelFailure("outside the panel root: \(relative)"))
        }
        return .success(target)
    }

    /// One directory, directories first, `.git` left out.
    ///
    /// `ignoredNames` is the subset git ignores, computed by the caller because only the
    /// caller knows whether there is a repository at all. Symlinks are listed by what they
    /// point at; following one that leads out of the root is refused later, by `resolve`,
    /// when it is opened.
    static func list(
        root: String, relative: String, ignoredNames: (URL, [String]) -> Set<String> = { _, _ in [] }
    ) -> Result<(entries: [Entry], truncated: Int), PanelFailure> {
        let directory: URL
        switch resolve(root: root, relative: relative) {
        case .success(let url): directory = url
        case .failure(let reason): return .failure(reason)
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            return .failure(PanelFailure("cannot list \(relative.isEmpty ? "the root" : relative): \(error.localizedDescription)"))
        }
        let visible = names.filter { $0 != ".git" && $0 != ".DS_Store" }
        let ignored = ignoredNames(directory, visible)
        var entries = visible.map { name -> Entry in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(name).path, isDirectory: &isDirectory)
            return Entry(name: name, isDirectory: isDirectory.boolValue, ignored: ignored.contains(name))
        }
        entries.sort { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        let truncated = max(0, entries.count - listLimit)
        return .success((Array(entries.prefix(listLimit)), truncated))
    }

    /// A text file's contents, or the reason it is not shown.
    static func read(root: String, relative: String) -> Result<String, PanelFailure> {
        let url: URL
        switch resolve(root: root, relative: relative) {
        case .success(let resolved): url = resolved
        case .failure(let reason): return .failure(reason)
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            return .failure(PanelFailure("cannot open \(relative): \(error.localizedDescription)"))
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            return .failure(PanelFailure("\(relative) is not a regular file"))
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= readLimit else {
            let megabytes = String(format: "%.1f", Double(size) / 1_048_576)
            return .failure(PanelFailure("too large to show: \(megabytes) MB, the viewer's limit is 2 MB"))
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failure(PanelFailure("cannot read \(relative): \(error.localizedDescription)"))
        }
        if data.prefix(binaryProbe).contains(0) {
            return .failure(PanelFailure("binary file, not shown"))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(PanelFailure("not UTF-8 text, not shown"))
        }
        return .success(text)
    }
}
