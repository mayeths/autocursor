// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutoCursor",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "autocursor", targets: ["AutoCursor"])
    ],
    targets: [
        .executableTarget(name: "AutoCursor")
    ]
)
