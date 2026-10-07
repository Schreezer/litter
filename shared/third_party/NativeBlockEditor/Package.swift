// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NativeBlockEditor",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "NativeBlockEditorEngine", targets: ["NativeBlockEditorEngine"]),
        .library(name: "NativeBlockEditorLibrary", targets: ["NativeBlockEditorLibrary"]),
        .library(name: "NativeBlockEditorCore", targets: ["NativeBlockEditorCore"]),
        .library(name: "NativeBlockEditorUI", targets: ["NativeBlockEditorUI"]),
        .library(name: "NativeEditorMCP", targets: ["NativeEditorMCP"]),
        .executable(name: "native-editor-evidence-helper", targets: ["NativeEditorEvidenceHelper"]),
    ],
    targets: [
        .target(name: "NativeBlockEditorEngine"),
        .target(
            name: "NativeBlockEditorLibrary",
            dependencies: ["NativeBlockEditorEngine"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "NativeBlockEditorCore",
            dependencies: ["NativeBlockEditorEngine", "NativeBlockEditorLibrary"]
        ),
        .target(
            name: "NativeBlockEditorUI",
            dependencies: ["NativeBlockEditorEngine"]
        ),
        .target(
            name: "NativeEditorMCP",
            dependencies: ["NativeBlockEditorCore"]
        ),
        .executableTarget(
            name: "NativeEditorEvidenceHelper",
            dependencies: [
                "NativeBlockEditorCore",
                "NativeBlockEditorLibrary",
                "NativeEditorMCP",
            ]
        ),
        .testTarget(
            name: "NativeEditorMCPTests",
            dependencies: ["NativeBlockEditorCore", "NativeEditorMCP"]
        ),
        .testTarget(
            name: "NativeBlockEditorUITests",
            dependencies: ["NativeBlockEditorEngine", "NativeBlockEditorUI"]
        ),
    ]
)
