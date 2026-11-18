// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Lamplight",
    platforms: [.macOS(.v14)],
    targets: [
        // A few lines of Objective-C: Swift cannot catch the exceptions AVFoundation raises.
        .target(
            name: "ObjCSafe",
            path: "Sources/ObjCSafe"
        ),
        .executableTarget(
            name: "Lamplight",
            dependencies: ["ObjCSafe"],
            path: "Sources/Lamplight"
        ),
    ]
)
