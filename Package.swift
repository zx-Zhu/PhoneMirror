// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhoneMirror",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PhoneMirror", targets: ["PhoneMirror"])
    ],
    targets: [
        .executableTarget(
            name: "PhoneMirror",
            path: "Sources/PhoneMirror"
        ),
        .testTarget(
            name: "PhoneMirrorTests",
            dependencies: ["PhoneMirror"],
            path: "Tests/PhoneMirrorTests"
        )
    ]
)
