// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CastKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "CastKit", targets: ["CastKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.28.0"),
    ],
    targets: [
        .target(
            name: "CastKit",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
    ]
)
