// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrailPoint",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TrailPoint", targets: ["TrailPoint"])],
    targets: [.executableTarget(name: "TrailPoint", path: ".", exclude: ["README.md", "USAGE.md", "LICENSE", "AppInfo.plist", "build-app.sh", "TrailPoint.app"], sources: ["Main.swift"])]
)
