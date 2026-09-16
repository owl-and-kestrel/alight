// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "Alight",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "Alight", targets: ["Alight"])
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.9.4")
  ],
  targets: [
    .executableTarget(
      name: "Alight",
      dependencies: [
        .product(name: "Sparkle", package: "Sparkle")
      ],
      path: "Sources/Alight"
    ),
    .testTarget(
      name: "AlightTests",
      dependencies: ["Alight"],
      path: "Tests/AlightTests"
    )
  ]
)
