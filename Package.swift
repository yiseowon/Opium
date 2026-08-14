// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocalAgent",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "LocalAgent", targets: ["LocalAgent"])],
    targets: [.executableTarget(name: "LocalAgent")]
)
