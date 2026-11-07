// swift-tools-version:6.0
import PackageDescription

// App extensions are plain executables whose entry point is NSExtensionMain; scripts/build-app.sh wraps them in .appex bundles.
let appexLinker: [LinkerSetting] = [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain", "-Xlinker", "-application_extension"])]
let appexSwift: [SwiftSetting] = [.swiftLanguageMode(.v5), .unsafeFlags(["-application-extension"])]

let package = Package(
    name: "Daisyshot",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Daisyshot",
            path: "Sources/Daisyshot",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        // Annotate + Pin share extensions (one binary, mode picked by bundle id).
        .executableTarget(name: "DaisyshotShareExtension", path: "Extensions/Share",
                          swiftSettings: appexSwift, linkerSettings: appexLinker),
        // Quick Look preview + thumbnail extensions for .daisyshot (one binary, two principal classes).
        .executableTarget(name: "DaisyshotQuickLookExtension", path: "Extensions/QuickLook", swiftSettings: appexSwift,
                          linkerSettings: appexLinker + [.linkedFramework("QuickLookUI"), .linkedFramework("QuickLookThumbnailing")]),
    ]
)
