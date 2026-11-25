// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DingLaterMac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "DingLaterMac", targets: ["DingLaterMac"])],
    targets: [
        .target(name: "DingTalkVFS",
                path: "Sources/DingTalkVFS",
                linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "DingLaterCore", dependencies: ["DingTalkVFS"]),
        .executableTarget(name: "DingLaterMac", dependencies: ["DingLaterCore"]),
        .testTarget(name: "DingLaterCoreTests", dependencies: ["DingLaterCore"])
    ]
)

