// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UebersichtCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "UebersichtCore", targets: ["UebersichtCore"])
    ],
    targets: [
        .target(name: "UebersichtCore"),
        .testTarget(name: "UebersichtCoreTests", dependencies: ["UebersichtCore"]),
    ]
)
