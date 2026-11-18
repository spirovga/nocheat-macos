// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Nocheat",
    platforms: [.macOS("14.4")],
    targets: [.executableTarget(name: "Nocheat", path: "Sources/Nocheat")]
)
