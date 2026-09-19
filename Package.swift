// swift-tools-version:5.9
import PackageDescription

// FalconCore is the platform library behind FalconMail: IMAP, SMTP, MIME,
// OAuth, file-based local cache, sync engine, rules, archive format and
// cloud storage backends. It has zero third-party dependencies.
let package = Package(
    name: "FalconCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FalconCore", targets: ["FalconCore"])
    ],
    targets: [
        .target(
            name: "FalconCore",
            path: "Sources/FalconCore"
        ),
        .testTarget(
            name: "FalconCoreTests",
            dependencies: ["FalconCore"],
            path: "Tests/FalconCoreTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
