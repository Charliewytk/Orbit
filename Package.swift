// swift-tools-version:5.10
import PackageDescription

// OrbitCore holds all of Orbit's logic that doesn't depend on UI: models, the
// scheduler, AI routing, email/calendar/ELE/OneNote clients and parsers.
// It builds and tests on Linux too, so it can be verified without Xcode.
let package = Package(
    name: "OrbitCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "OrbitCore", targets: ["OrbitCore"]),
    ],
    targets: [
        .target(name: "OrbitCore", path: "Sources/OrbitCore"),
        .testTarget(name: "OrbitCoreTests", dependencies: ["OrbitCore"], path: "Tests/OrbitCoreTests"),
    ]
)
