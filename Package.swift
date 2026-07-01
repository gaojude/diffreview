// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MyIDE",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/smittytone/HighlighterSwift.git", from: "3.1.0"),
    ],
    targets: [
        // Pure, Foundation-only logic — no SwiftUI/AppKit, so it is directly
        // exercisable by the self-test executable without needing Xcode/XCTest.
        .target(
            name: "MyIDECore",
            path: "Sources/MyIDECore"
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
            dependencies: ["MyIDECore"],
            path: "Sources/MyIDESelfTest"
        ),
    ]
)
