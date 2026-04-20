// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "CodexRemoteV2Client",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "CodexRemoteV2Client",
            targets: ["CodexRemoteV2Client"]
        ),
        .executable(
            name: "CodexRemoteV2ClientDemo",
            targets: ["CodexRemoteV2ClientDemo"]
        ),
    ],
    targets: [
        .target(
            name: "CodexRemoteV2Client"
        ),
        .executableTarget(
            name: "CodexRemoteV2ClientDemo",
            dependencies: ["CodexRemoteV2Client"]
        ),
    ]
)
