// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ElectroPiano",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ElectroProUI", type: .static, targets: ["ElectroProUI"]),
        .executable(name: "ElectroPiano", targets: ["ElectroPiano"]),
        .executable(name: "npno-cli", targets: ["npno-cli"]),
    ],
    targets: [
        // Núcleo C++20: parser/decodificador .npno, instrumento e motor polifônico (sem dependências de SO).
        .target(
            name: "NPNOKit",
            path: "Sources/NPNOKit",
            cxxSettings: [.unsafeFlags(["-O3"])]
        ),
        // Ponte C (para o Swift) + saída CoreAudio + entrada CoreMIDI.
        .target(
            name: "NPNOBridge",
            dependencies: ["NPNOKit"],
            path: "Sources/NPNOBridge",
            cxxSettings: [.unsafeFlags(["-O3"])],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreMIDI"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        // Ferramenta de inspeção / validação / exportação WAV.
        .executableTarget(
            name: "npno-cli",
            dependencies: ["NPNOKit"],
            path: "Sources/npno-cli",
            cxxSettings: [.unsafeFlags(["-O3"])]
        ),
        // UI compartilhada (Standalone + AU + VST3) em SwiftUI (macOS 26.0 Tahoe).
        .target(
            name: "ElectroProUI",
            dependencies: ["NPNOBridge"],
            path: "Sources/ElectroProUI",
            resources: [
                .process("Resources")
            ]
        ),
        // Aplicativo Standalone SwiftUI (macOS 26.0 Tahoe).
        .executableTarget(
            name: "ElectroPiano",
            dependencies: ["ElectroProUI"],
            path: "Sources/ElectroPianoApp"
        ),
        .testTarget(
            name: "ElectroPianoTests",
            dependencies: ["NPNOBridge"],
            path: "Tests/ElectroPianoTests"
        ),
    ],
    cxxLanguageStandard: .cxx20
)
