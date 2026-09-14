// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UebersichtCore",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ubersichtd", targets: ["ubersichtd"]),
    ],
    targets: [
        .target(
            name: "UebersichtCore",
            resources: [.copy("Resources/transform-kernel.js")]
        ),
        .executableTarget(name: "ubersichtd", dependencies: ["UebersichtCore"]),
        .testTarget(name: "UebersichtCoreTests", dependencies: ["UebersichtCore"]),
    ]
)
