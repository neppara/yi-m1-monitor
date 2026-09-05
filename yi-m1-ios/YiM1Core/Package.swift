// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "YiM1Core",
    platforms: [
        .iOS(.v15),
        .macOS(.v13), // host platform, lets us `swift test` pure logic without a simulator
    ],
    products: [
        .library(name: "YiM1Core", targets: ["YiM1Core"]),
    ],
    targets: [
        .target(name: "YiM1Core"),
        .testTarget(name: "YiM1CoreTests", dependencies: ["YiM1Core"]),
    ]
)
