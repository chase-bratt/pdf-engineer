// swift-tools-version: 6.0
import PackageDescription

// One module per concern, so each layer can be built and tested in isolation.
//
// Dependency direction is strictly downward: App -> DocumentModel -> {PDFCore, ...}.
// PDFCore depends on nothing in this package. Cycles are a build error, by design.

let swiftSettings: [SwiftSetting] = [
    // PDFKit carries zero concurrency annotations, so strict
    // checking is the only thing that will surface unsafe sharing at compile time.
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "pdf-engineer",
    platforms: [
        // macOS 26 is the floor so Vision's
        // RecognizeDocumentsRequest (macOS 26.0+) is unconditionally available.
        .macOS("26.0"),
    ],
    products: [
        .library(name: "PDFCore", targets: ["PDFCore"]),
        .library(name: "DocumentModel", targets: ["DocumentModel"]),
        .library(name: "OCR", targets: ["OCR"]),
        .library(name: "Export", targets: ["Export"]),
        .library(name: "MCPServer", targets: ["MCPServer"]),
        .library(name: "Assistant", targets: ["Assistant"]),
        .executable(name: "pdfeng", targets: ["pdfeng"]),
        .executable(name: "PDFEngineer", targets: ["PDFEngineerApp"]),
        .executable(name: "pdfeng-mcp", targets: ["pdfeng-mcp"]),
    ],
    dependencies: [
        // Official MCP Swift SDK. 0.12.1 is the version verified to resolve and
        // build against this toolchain.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        // On-device LLM. MLXLLM lives in mlx-swift-lm, NOT mlx-swift-examples
        // (which now ships only MNIST and StableDiffusion).
        //
        // Pinned to an exact commit (the one Package.resolved had locked from
        // `main`): a branch dependency means any push upstream changes what a
        // fresh resolve builds and ships. Bump deliberately, after review.
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            revision: "5e46681b2adcef2db158e7b949aeae3896778e23"
        ),
        // Required directly: #huggingFaceTokenizerLoader() is a macro whose
        // expansion needs `Tokenizers` in scope.
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        // ── Core: PDF object model, xref, content streams ──────────────────────
        .target(
            name: "PDFCore",
            swiftSettings: swiftSettings
        ),

        // ── Document model: immutable snapshots, Command/inverse, undo ─────────
        .target(
            name: "DocumentModel",
            dependencies: ["PDFCore"],
            swiftSettings: swiftSettings
        ),

        // ── OCR: Vision pipeline producing a positioned text-layer model ───────
        // Produces a model only; never writes PDF bytes, so PDF writing stays in
        // one place.
        .target(
            name: "OCR",
            dependencies: ["PDFCore"],
            swiftSettings: swiftSettings
        ),

        // ── Export: DocAST -> Markdown / JSON / LLM bundle ─────────────────────
        .target(
            name: "Export",
            dependencies: ["PDFCore", "OCR"],
            swiftSettings: swiftSettings
        ),

        // ── MCP server: tool surface over DocumentModel commands ───────────────
        // Depends on DocumentModel so every mutation is a Command and inherits
        // undo + consent.
        .target(
            name: "MCPServer",
            dependencies: [
                "DocumentModel", "Export",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: swiftSettings
        ),

        // ── Assistant: on-device LLM intent parsing ───────────────────────────
        // The model only turns a request into a structured command; our tested
        // code executes it, so a 1.7B model can never corrupt a document.
        .target(
            name: "Assistant",
            dependencies: [
                "DocumentModel", "PDFCore",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: swiftSettings
        ),

        // ── App: SwiftUI shell + AppKit canvas ─────────────────────────────────
        .executableTarget(
            name: "PDFEngineerApp",
            dependencies: ["PDFCore", "DocumentModel", "OCR", "Export", "MCPServer", "Assistant"],
            swiftSettings: swiftSettings
        ),

        // ── MCP stdio helper ──────────────────────────────────────────────────
        // Ships inside the .app bundle; Claude Code/Desktop launch it over
        // stdio.
        .executableTarget(
            name: "pdfeng-mcp",
            dependencies: [
                "MCPServer", "DocumentModel",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: swiftSettings
        ),

        // ── CLI: shares the engine modules, no GUI ─────────────────────────────
        .executableTarget(
            name: "pdfeng",
            dependencies: ["PDFCore", "DocumentModel", "OCR", "Export", "Assistant"],
            swiftSettings: swiftSettings
        ),

        // ── Tests ─────────────────────────────────────────────────────────────
        .testTarget(name: "PDFCoreTests", dependencies: ["PDFCore"], swiftSettings: swiftSettings),
        .testTarget(name: "DocumentModelTests", dependencies: ["DocumentModel"], swiftSettings: swiftSettings),
        .testTarget(name: "OCRTests", dependencies: ["OCR"], swiftSettings: swiftSettings),
        .testTarget(name: "ExportTests", dependencies: ["Export"], swiftSettings: swiftSettings),
        .testTarget(name: "MCPServerTests", dependencies: ["MCPServer"], swiftSettings: swiftSettings),
        .testTarget(name: "AssistantTests", dependencies: ["Assistant"], swiftSettings: swiftSettings),
    ]
)
