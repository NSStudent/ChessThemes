// swift-tools-version: 6.0

// Herramienta de medida: extrae las jugadas de un PGN con fischer-core a una caché binaria
// y mide ChessThemes sobre ella (tiempo por partida, frecuencia por tema, muestras para revisar).
// Paquete aparte para que los usuarios de la librería no la compilen.

import PackageDescription

let package = Package(
    name: "ThemesBench",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/NSStudent/fischer-core.git", from: "0.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "themes-bench",
            dependencies: [
                .product(name: "ChessThemes", package: "ChessThemes"),
                .product(name: "FischerCore", package: "fischer-core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
