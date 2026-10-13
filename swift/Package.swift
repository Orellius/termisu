// swift-tools-version: 5.9
// The minimal Swift host -- slice 8. Build from this directory (`swift build` resolves the
// -L flag against the invoking directory), or use scripts/build-swift.sh which does both
// halves: the Rust archive first, then this.
import PackageDescription

let package = Package(
    name: "termisu-host",
    platforms: [.macOS("26.0")],
    targets: [
        // The C surface, imported straight from the crate's own header -- one source of
        // truth, no copied declarations.
        .systemLibrary(name: "CTermisuHost", path: "Sources/CTermisuHost"),
        .executableTarget(
            name: "termisu-host",
            dependencies: ["CTermisuHost"],
            path: "Sources/termisu-host",
            linkerSettings: [
                .unsafeFlags(["-L../target/release"]),
                .linkedLibrary("termisu-vt-host"),
                // wgpu's Metal backend.
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("AppKit"),
                // S6 panels: the WKWebView that renders them.
                .linkedFramework("WebKit"),
            ]
        ),
    ]
)
