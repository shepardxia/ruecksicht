// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UebersichtCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "UebersichtCore", targets: ["UebersichtCore"]),
        .executable(name: "ubersichtd", targets: ["ubersichtd"]),
    ],
    targets: [
        .target(name: "UebersichtCore"),
        .executableTarget(name: "ubersichtd", dependencies: ["UebersichtCore"]),
    ]
)
