// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ChessThemes",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "ChessThemes", targets: ["ChessThemes"]),
    ],
    dependencies: [
        .package(url: "https://github.com/NSStudent/fischer-core.git", from: "0.4.0"),
    ],
    targets: [
        .target(
            name: "ChessThemes",
            dependencies: [
                .product(name: "FischerCore", package: "fischer-core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ChessThemesTests",
            dependencies: [
                "ChessThemes",
                .product(name: "FischerCore", package: "fischer-core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
