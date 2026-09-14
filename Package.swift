// swift-tools-version: 5.9
import PackageDescription

// Module names can't contain hyphens, so the target is WebRunner while the
// shipped app is branded "Web-Runner".
let package = Package(
    name: "WebRunner",
    platforms: [.macOS(.v10_15)],
    targets: [
        .executableTarget(name: "WebRunner", path: "Sources")
    ]
)
