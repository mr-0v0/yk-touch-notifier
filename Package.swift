// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "yk-touch-notifier",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "YKTouchCore"),
        .executableTarget(name: "YKTouchNotifier", dependencies: ["YKTouchCore"]),
        .executableTarget(name: "selfcheck", dependencies: ["YKTouchCore"]),
    ]
)
