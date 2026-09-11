// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NyxCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "NyxCore", targets: ["NyxCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(name: "NyxCore",
                dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "NyxCoreTests", dependencies: ["NyxCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
