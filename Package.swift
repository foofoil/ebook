// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ebook",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "EBookExtensionCore", targets: ["EBookExtensionCore"]),
        .library(name: "EBookExtensionRuntime", type: .dynamic, targets: ["EBookExtensionRuntime"]),
        .executable(name: "ebook-inspect", targets: ["EBookInspect"]),
        .executable(name: "ebook-runtime-smoke", targets: ["EBookRuntimeSmoke"])
    ],
    dependencies: [
        // 仅 smoke／契约测试使用，生产 Core/Runtime 不依赖 extension-kit。
        .package(path: "../extension-kit")
    ],
    targets: [
        .target(name: "EBookExtensionCore"),
        .target(name: "EBookExtensionRuntime", dependencies: ["EBookExtensionCore"]),
        .target(name: "EBookTestSupport", dependencies: ["EBookExtensionCore"]),
        .executableTarget(name: "EBookInspect", dependencies: ["EBookExtensionCore"]),
        .executableTarget(
            name: "EBookRuntimeSmoke",
            dependencies: [
                "EBookExtensionCore",
                "EBookExtensionRuntime",
                "EBookTestSupport",
                .product(name: "FoofoilExtensionKit", package: "extension-kit")
            ]
        ),
        .testTarget(
            name: "EBookExtensionCoreTests",
            dependencies: ["EBookExtensionCore", "EBookTestSupport"]
        ),
        .testTarget(
            name: "EBookExtensionRuntimeTests",
            dependencies: ["EBookExtensionRuntime", "EBookExtensionCore", "EBookTestSupport"]
        )
    ]
)
