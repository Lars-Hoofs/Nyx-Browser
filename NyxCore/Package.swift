// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NyxCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "NyxCore", targets: ["NyxCore"])
    ],
    targets: [
        .target(name: "NyxCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "NyxCoreTests", dependencies: ["NyxCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
