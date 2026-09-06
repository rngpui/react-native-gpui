// swift-tools-version: 6.4
import PackageDescription

var packageDependencies: [Package.Dependency] = [
    .package(path: "engine"),
    .package(name: "Nucleus", path: ".."),
    .package(url: "https://github.com/apple/swift-async-algorithms.git", from: "1.1.5"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
    .package(url: "https://github.com/apple/containerization.git", exact: "0.43.0"),
]
let nucleusSessionDependencies: [Target.Dependency] = [
    .product(
        name: "NucleusSessionProtocol",
        package: "Nucleus",
        condition: .when(platforms: [.linux]))
]
let nucleusAndroidRuntimeDependencies: [Target.Dependency] = [
    .product(
        name: "NucleusAndroidRuntimeCore",
        package: "Nucleus",
        condition: .when(platforms: [.linux]))
]

let package = Package(
    name: "collider-cli",
    platforms: [.macOS("27")],
    products: [
        .executable(name: "collider", targets: ["Collider"]),
        .executable(
            name: "nucleus-nightly-reservation",
            targets: ["NucleusNightlyReservation"]),
        .executable(
            name: "nucleus-linux-assembler",
            targets: ["NucleusLinuxAssembler"]),
        .executable(
            name: "nucleus-linux-runtime-publisher",
            targets: ["NucleusLinuxRuntimePublisher"]),
        .executable(
            name: "nucleus-linux-package-qualifier",
            targets: ["NucleusLinuxPackageQualifier"]),
        .executable(
            name: "nucleus-android-assembler",
            targets: ["NucleusAndroidAssembler"]),
    ],
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "NightlyReleaseContracts",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(name: "NightlyReservationStorageC"),
        .target(
            name: "NightlyReleaseReservations",
            dependencies: ["NightlyReleaseContracts", "NightlyReservationStorageC"]),
        .executableTarget(
            name: "NucleusNightlyReservation",
            dependencies: ["NightlyReleaseContracts", "NightlyReleaseReservations"]),
        .testTarget(
            name: "NightlyReleaseReservationTests",
            dependencies: [
                "NightlyReleaseContracts", "NightlyReleaseReservations",
                "NucleusNightlyReservation",
                .product(name: "ColliderCore", package: "engine"),
            ]),
        .executableTarget(
            name: "Collider",
            dependencies: ["ColliderCLI"]),
        .executableTarget(
            name: "NucleusLinuxAssembler",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
                "LinuxPackageAssembly",
                "LinuxPackageContracts",
            ]),
        .executableTarget(
            name: "NucleusLinuxRuntimePublisher",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
                "ShellColliderRecipe",
            ]),
        .executableTarget(
            name: "NucleusAndroidAssembler",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
                "AndroidRuntimeColliderRecipe",
            ]),
        .executableTarget(
            name: "NucleusLinuxPackageQualifier",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderPersistence", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
                "LinuxPackageAssembly",
                "LinuxPackageContracts",
            ]),
        .target(
            name: "ColliderCLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(
                    name: "ColliderAppleContainer",
                    package: "engine",
                    condition: .when(platforms: [.macOS])),
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderPersistence", package: "engine"),
                .product(name: "ColliderProcess", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
                "ColliderWorkspaceCommands",
                .target(
                    name: "ColliderLinuxOperations",
                    condition: .when(platforms: [.linux])),
            ]),
        .target(
            name: "ColliderWorkspaceCommands",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderEngine", package: "engine"),
                .product(name: "ColliderPersistence", package: "engine"),
                .product(name: "ColliderProcess", package: "engine"),
                .product(name: "ColliderPlanning", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
                "ColliderSwiftPM",
                "AndroidRuntimeColliderRecipe",
                "ChromiumColliderRecipe",
                "CompositorColliderRecipe",
                "CoreColliderRecipe",
                "LinuxColliderRecipe",
                "LinuxPackageContracts",
                "NativeBuilderColliderRecipe",
                "ReactNativeColliderRecipe",
                "ReleaseGateColliderRecipe",
                "ShellColliderRecipe",
                "SwiftTargetSDKColliderRecipe",
                "VulkanColliderRecipe",
                "WaylandColliderRecipe",
            ]),
        .target(
            name: "ColliderLinuxOperations",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
                "ColliderWorkspaceCommands",
                "AndroidRuntimeColliderRecipe",
                "ShellColliderRecipe",
            ] + nucleusSessionDependencies + nucleusAndroidRuntimeDependencies),
        .target(
            name: "ColliderSwiftPM",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "AndroidRuntimeColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                "NativeBuilderColliderRecipe",
                "ShellColliderRecipe",
            ] + nucleusAndroidRuntimeDependencies),
        .target(
            name: "ChromiumColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                "LinuxPackageContracts",
            ]),
        .target(
            name: "CompositorColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                "NativeBuilderColliderRecipe",
            ]),
        .target(
            name: "CoreColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                "NativeBuilderColliderRecipe",
            ]),
        .target(
            name: "LinuxColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderPersistence", package: "engine"),
                "ChromiumColliderRecipe",
                "LinuxPackageAssembly",
                "LinuxPackageContracts",
                "NativeBuilderColliderRecipe",
                "ShellColliderRecipe",
            ]),
        .target(
            name: "LinuxPackageAssembly",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderPersistence", package: "engine"),
                "LinuxPackageContracts",
            ]),
        .target(
            name: "LinuxPackageContracts",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderPersistence", package: "engine"),
            ]),
        .target(
            name: "NativeBuilderColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "ReactNativeColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                "NativeBuilderColliderRecipe",
            ]),
        .target(
            name: "ReleaseGateColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                "NativeBuilderColliderRecipe",
            ]),
        .target(
            name: "ShellColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                "LinuxPackageContracts",
                "NativeBuilderColliderRecipe",
            ] + nucleusAndroidRuntimeDependencies),
        .target(
            name: "SwiftTargetSDKColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                "NativeBuilderColliderRecipe",
                .product(
                    name: "ContainerizationArchive",
                    package: "containerization"),
            ]),
        .target(
            name: "VulkanColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .target(
            name: "WaylandColliderRecipe",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                "NativeBuilderColliderRecipe",
            ]),
        .testTarget(
            name: "ChromiumColliderRecipeTests",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderEngine", package: "engine"),
                .product(name: "ColliderPersistence", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
                "ChromiumColliderRecipe",
                "LinuxPackageContracts",
            ]),
        .testTarget(
            name: "ColliderCLITests",
            dependencies: [
                "ColliderCLI",
                "ColliderWorkspaceCommands",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .target(
                    name: "ColliderLinuxOperations",
                    condition: .when(platforms: [.linux])),
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderPersistence", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
            ]),
        .testTarget(
            name: "ColliderWorkspaceCommandsTests",
            dependencies: [
                "ColliderWorkspaceCommands",
                "AndroidRuntimeColliderRecipe",
                "ChromiumColliderRecipe",
                "CompositorColliderRecipe",
                .product(
                    name: "ColliderAppleContainer",
                    package: "engine",
                    condition: .when(platforms: [.macOS])),
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderEngine", package: "engine"),
                .product(name: "ColliderPersistence", package: "engine"),
                .product(name: "ColliderPlanning", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
                .product(name: "ColliderTesting", package: "engine"),
                "CoreColliderRecipe",
                "LinuxColliderRecipe",
                "NativeBuilderColliderRecipe",
                "ReactNativeColliderRecipe",
                "ReleaseGateColliderRecipe",
                "SwiftTargetSDKColliderRecipe",
                "VulkanColliderRecipe",
                "WaylandColliderRecipe",
            ]),
        .testTarget(
            name: "ColliderLinuxOperationsTests",
            dependencies: [
                .target(
                    name: "ColliderLinuxOperations",
                    condition: .when(platforms: [.linux])),
                "ColliderWorkspaceCommands",
                "AndroidRuntimeColliderRecipe",
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderPersistence", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
            ] + nucleusSessionDependencies + nucleusAndroidRuntimeDependencies),
        .testTarget(
            name: "CoreColliderRecipeTests",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderEngine", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
                "CoreColliderRecipe",
            ]),
        .testTarget(
            name: "ColliderSwiftPMTests",
            dependencies: [
                "ColliderSwiftPM",
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderEngine", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
            ]),
        .testTarget(
            name: "SwiftTargetSDKColliderRecipeTests",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderEngine", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
                .product(name: "ColliderTesting", package: "engine"),
                "SwiftTargetSDKColliderRecipe",
            ]),
        .testTarget(
            name: "LinuxColliderRecipeTests",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                .product(name: "ColliderPersistence", package: "engine"),
                .product(name: "ColliderRuntime", package: "engine"),
                .product(name: "ColliderTesting", package: "engine"),
                "ChromiumColliderRecipe",
                "LinuxColliderRecipe",
                "LinuxPackageAssembly",
                "LinuxPackageContracts",
                "ShellColliderRecipe",
            ]),
        .testTarget(
            name: "ShellColliderRecipeTests",
            dependencies: [
                .product(name: "ColliderCore", package: "engine"),
                "LinuxPackageContracts",
                "NativeBuilderColliderRecipe",
                "ShellColliderRecipe",
            ]),
    ]
)

for target in package.targets {
    switch target.type {
    case .regular, .executable, .test:
        break
    default:
        continue
    }
    var swiftSettings =
        (target.swiftSettings ?? []) + [
            .interoperabilityMode(.Cxx),
            .strictMemorySafety(),
            .unsafeFlags(["-warnings-as-errors"]),
            .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
        ]
    if let feature = Context.environment["NUCLEUS_SWIFT_DIAGNOSTIC_FEATURE"] {
        swiftSettings.append(.unsafeFlags(["-enable-upcoming-feature", feature]))
    }
    target.swiftSettings = swiftSettings
    target.cSettings =
        (target.cSettings ?? []) + [
            .unsafeFlags(["-Werror"])
        ]
    target.cxxSettings =
        (target.cxxSettings ?? []) + [
            .unsafeFlags(["-Werror"])
        ]
}
