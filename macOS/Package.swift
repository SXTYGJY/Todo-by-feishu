// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TodoDesktop",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TodoDesktop", targets: ["TodoDesktop"])
    ],
    targets: [
        .executableTarget(
            name: "TodoDesktop",
            path: "Sources/TodoDesktop",
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "TodoDesktopTests",
            dependencies: ["TodoDesktop"],
            path: "Tests/TodoDesktopTests"
        )
    ]
)
