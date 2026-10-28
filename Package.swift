// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpicyLyrics",
    defaultLocalization: "en",
    platforms: [.iOS(.v17)],
    products: [.library(name: "SpicyLyrics", targets: ["SpicyLyrics"])],
    dependencies: [.package(url: "https://github.com/spotify/ios-sdk", from: "5.0.1")],
    targets: [
        .target(
            name: "SpicyLyrics",
            dependencies: [.product(name: "SpotifyiOS", package: "ios-sdk")],
            path: "SpicyLyrics",
            exclude: ["Assets.xcassets", "Background/Shaders.metal"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
