// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TravelPlannerKit",
    defaultLocalization: "de",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TravelPlannerKit", targets: ["TravelPlannerKit"]),
    ],
    targets: [
        .target(name: "TravelPlannerKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "TravelPlannerKitTests", dependencies: ["TravelPlannerKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
