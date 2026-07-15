// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MyIDE",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Vendored (Vendor/HighlighterSwift) with one change: resource-bundle
        // resolution that works inside the packaged .app and fails soft. The
        // upstream release relies on SwiftPM's generated `Bundle.module`,
        // which traps outside the original build directory (0.1.0 crash).
        .package(path: "Vendor/HighlighterSwift"),
    ],
    targets: [
        // Pure, Foundation-only logic — no SwiftUI/AppKit, so it is directly
        // exercisable by the self-test executable without needing Xcode/XCTest.
        .target(
            name: "MyIDECore",
            path: "Sources/MyIDECore"
        ),
        // Prose-review logic for Margin (selections, comments, formatter, store) — same
        // pure-Foundation rule as MyIDECore, covered by the same self-test executable.
        .target(
            name: "MarginCore",
            path: "Sources/MarginCore"
        ),
        // Margin: review an agent's reply like a diff — pipe a markdown file in, select
        // exact passages, comment in a pane, copy the review as one prompt-ready block.
        .executableTarget(
            name: "Margin",
            dependencies: ["MarginCore"],
            path: "Sources/Margin"
        ),
        // The native SwiftUI/AppKit application.
        .executableTarget(
            name: "MyIDE",
            dependencies: [
                "MyIDECore",
                .product(name: "Highlighter", package: "HighlighterSwift"),
            ],
            path: "Sources/MyIDE"
        ),
        // Logic self-test harness. Runs assertions against MyIDECore and exits
        // non-zero on failure. Works under Command Line Tools (no `xctest`).
        .executableTarget(
            name: "MyIDESelfTest",
            dependencies: ["MyIDECore", "MarginCore"],
            path: "Sources/MyIDESelfTest"
        ),
    ]
)
