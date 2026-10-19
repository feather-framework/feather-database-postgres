// swift-tools-version:6.3
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .strictMemorySafety(),
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .enableUpcomingFeature("StrictConcurrency"),
    .enableExperimentalFeature("SuppressedAssociatedTypes"),
    .enableExperimentalFeature("LifetimeDependence"),
    .enableExperimentalFeature("Lifetimes"),
]

let package = Package(
    name: "feather-database-postgres",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: [
        .library(
            name: "FeatherDatabasePostgres",
            targets: ["FeatherDatabasePostgres"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log", from: "1.16.1"),
        .package(url: "https://github.com/vapor/postgres-nio", from: "1.33.1"),
        .package(
            url: "https://github.com/feather-framework/feather-database",
            exact: "1.0.0-rc.3"
        ),
    ],
    targets: [
        .target(
            name: "FeatherDatabasePostgres",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "FeatherDatabase", package: "feather-database"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "FeatherDatabasePostgresTests",
            dependencies: [
                .target(name: "FeatherDatabasePostgres")
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
