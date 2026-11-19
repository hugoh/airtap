// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "airtap",
    platforms: [.macOS("14.2")],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.3.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "AirtapCore", dependencies: ["BigInt"]),
        .executableTarget(
            name: "airtap",
            dependencies: ["AirtapCore", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .executableTarget(
            name: "AirtapApp",
            dependencies: ["AirtapCore"],
            exclude: ["Info.plist", "AppIcon.icns"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Sources/AirtapApp/Info.plist"])]
        ),
        .executableTarget(
            name: "TestTone",
            exclude: ["Info.plist"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Sources/TestTone/Info.plist"])]
        ),
        .testTarget(name: "AirtapCoreTests", dependencies: ["AirtapCore"]),
        .testTarget(name: "AirtapCLITests", dependencies: ["airtap"]),
    ]
)
