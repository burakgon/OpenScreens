// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OpenScreensKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "OpenScreensCore", targets: ["OpenScreensCore"]),
        .library(name: "OpenScreensUI", targets: ["OpenScreensUI"]),
    ],
    dependencies: [
        // Remote-desktop engine: RFB, Apple Screen Sharing (Standard and High
        // Performance), remote audio and clipboard. MIT licensed, vendored with
        // a small set of local changes — see Vendor/README.md.
        .package(path: "../../Vendor/rootshell-vnc"),
        // SSH transport used for secure tunnels and SFTP file transfer.
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.15.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.95.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.26.0"),
    ],
    targets: [
        // Models, persistence, discovery, networking helpers. No UI.
        .target(
            name: "OpenScreensCore",
            dependencies: [
                .product(name: "RFBProtocol", package: "rootshell-vnc"),
                .product(name: "RFBTransport", package: "rootshell-vnc"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // SwiftUI interface, session controller and the platform remote canvases.
        .target(
            name: "OpenScreensUI",
            dependencies: [
                "OpenScreensCore",
                .product(name: "rootshellVNC", package: "rootshell-vnc"),
                .product(name: "RFBProtocol", package: "rootshell-vnc"),
                .product(name: "RFBTransport", package: "rootshell-vnc"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),

        .testTarget(
            name: "OpenScreensCoreTests",
            dependencies: ["OpenScreensCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
