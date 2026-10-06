// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PageEditBenchmark",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../shared/third_party/NativeBlockEditor")],
    targets: [.executableTarget(
        name: "PageEditBridge",
        dependencies: [
            .product(name: "NativeEditorMCP", package: "NativeBlockEditor"),
            .product(name: "NativeBlockEditorCore", package: "NativeBlockEditor"),
        ]
    )]
)
