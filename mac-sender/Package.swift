// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipboardSender",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "clipboard-sender",
            path: "Sources"
        )
    ]
)
