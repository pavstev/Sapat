// swift-tools-version: 6.0
import PackageDescription

// SwiftPM build path — lets Šapat build with just the Command Line Tools (no full
// Xcode). `./bundle.sh` wraps the resulting binary into Sapat.app. The Xcode route
// via project.yml/XcodeGen still works too if you ever install Xcode.
//
// The global hotkey uses Carbon's RegisterEventHotKey directly (see GlobalHotKey.swift)
// rather than the KeyboardShortcuts package, which relies on the #Preview macro plugin
// that ships only with Xcode and so won't compile under CLT.
let package = Package(
    name: "Sapat",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.0.0"),
        // Local semantic-memory store. Macro-free (no Xcode plugin), links the system
        // SQLite, and its SwiftPM package enables FTS5 — so it builds under the CLT.
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Sapat",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "SapatTests",
            dependencies: ["Sapat"],
            path: "Tests/SapatTests"
        )
    ]
)
