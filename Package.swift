// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OmniShot",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 自动更新；二进制包，只需 Command Line Tools
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // 不依赖 AppKit 的纯逻辑：坐标换算、文本分块、取色、翻译接口
        .target(name: "OmniShotCore"),
        // 菜单栏应用：截图覆盖层、标注、翻译回显、贴图、设置
        .executableTarget(
            name: "OmniShot",
            dependencies: ["OmniShotCore", .product(name: "Sparkle", package: "Sparkle")],
            // The icons are the libraries' own SVG files; build-app.sh copies the bundle they end up in.
            resources: [.copy("Icons"), .copy("Models"), .copy("Recommends")],
            // Sparkle.framework is embedded in OmniShot.app/Contents/Frameworks by scripts/build-app.sh.
            // `-platform_version` pins the minimum OS to 14 but records the SDK version as 26.2. SwiftPM
            // otherwise records the deployment target (14.0) as the SDK, which makes macOS fall back to
            // the old window chrome: the sidebar toggle sits in the titlebar and the split view's
            // material/geometry differ from DockMinimize (which is linked against 26.2).
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                "-Xlinker", "-platform_version", "-Xlinker", "macos",
                "-Xlinker", "14.0", "-Xlinker", "26.2",
            ])]
        ),
        .testTarget(name: "OmniShotCoreTests", dependencies: ["OmniShotCore"]),
    ],
    swiftLanguageModes: [.v5]
)
