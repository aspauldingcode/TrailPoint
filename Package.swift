// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrailPoint",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TrailPoint", targets: ["TrailPoint"])],
    targets: [.executableTarget(
        name: "TrailPoint",
        path: ".",
        exclude: [
            "README.md", "USAGE.md", "LICENSE", "AppInfo.plist", "TrailPoint.entitlements",
            "build-app.sh", "TrailPoint.app", "AppIcon.icon", "AppIcon.icns", "scripts", "Media"
        ],
        sources: ["Main.swift"]
    )]
)
