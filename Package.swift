// swift-tools-version: 6.0
import PackageDescription

// Foundation-only scheduling tests; this package does not build the iOS application.
let package = Package(
    name: "AirPodsTranslatorCore",
    products: [.library(name: "AirPodsTranslator", targets: ["AirPodsTranslator"])],
    targets: [
        .target(name: "AirPodsTranslator", path: "Sources/Core"),
        .testTarget(name: "AirPodsTranslatorTests", dependencies: ["AirPodsTranslator"], path: "Tests")
    ],
    swiftLanguageModes: [.v5]
)
