// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HikvisionViewer",
    platforms: [.macOS(.v13)],
    products: [.library(name: "CameraCore", targets: ["CameraCore"])],
    targets: [
        .target(name: "CameraCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "CameraCoreTests", dependencies: ["CameraCore"])
    ]
)
