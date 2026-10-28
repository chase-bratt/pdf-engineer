import Foundation
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// The on-device model, loaded in-process.
///
/// Runs `mlx-community/Qwen3-1.7B-4bit` via MLX, with no Python, no subprocess,
/// and no network. Measured on this machine: **0.78 s to load, ~3 s per reply,
/// ~1 GB peak**.
///
/// The model's only job is to turn a sentence into an ``Intent``. See that type
/// for why the boundary is drawn there.
public actor LocalLLM {

    /// Where the assistant stands.
    public enum Status: Sendable, Equatable {
        case notLoaded
        case loading
        case ready
        /// Loading failed. The message is shown in the sidebar; the rest of the
        /// app is unaffected.
        case unavailable(String)
    }

    private var container: ModelContainer?
    public private(set) var status: Status = .notLoaded

    /// Hugging Face repo id, used to locate the cached snapshot.
    private let modelID = "mlx-community/Qwen3-1.7B-4bit"

    public init() {}

    /// Loads the model if it is not already loaded.
    ///
    /// Idempotent, so the UI can call it on first message without tracking
    /// state itself.
    public func prepare() async {
        switch status {
        case .ready, .loading: return
        default: break
        }

        status = .loading

        guard let directory = Self.cachedModelDirectory(for: modelID) else {
            status = .unavailable(
                """
                Model not found. Download it with:

                    pip install mlx-lm
                    python3 -m mlx_lm generate --model \(modelID) --prompt hi
                """
            )
            return
        }

        do {
            // Loading from a local directory needs no downloader, so the app
            // never reaches the network.
            let loaded = try await loadModelContainer(
                from: directory,
                using: #huggingFaceTokenizerLoader()
            )
            container = loaded
            status = .ready
        } catch {
            status = .unavailable("Could not load the model: \(error.localizedDescription)")
        }
    }

    /// Maps a user request onto an ``Intent``.
    ///
    /// - Parameter pageCount: Included in the prompt so page references can be
    ///   resolved ("the last page") without a second round trip.
    public func intent(for request: String, pageCount: Int) async -> Intent {
        await prepare()
        guard case .ready = status, let container else {
            if case let .unavailable(message) = status {
                return .unsupported(reason: message)
            }
            return .unsupported(reason: "The assistant is not available.")
        }

        let prompt = """
            Document has \(pageCount) pages.
            Request: \(request)
            """

        do {
            // A fresh ChatSession per request. It is not Sendable, so it cannot
            // be stored on this actor — and each request is independent anyway,
            // so there is no conversation state worth carrying.
            let session = ChatSession(container, instructions: Self.systemPrompt)
            let reply = try await session.respond(to: prompt)
            return IntentParser.parse(reply)
        } catch {
            return .unsupported(reason: "The assistant failed: \(error.localizedDescription)")
        }
    }

    /// Drops the model from memory.
    ///
    /// ~1 GB is worth reclaiming when the sidebar is closed on a machine that
    /// is also holding a large PDF.
    public func unload() {
        container = nil
        status = .notLoaded
    }

    // MARK: - Prompt

    /// Instructions for the model.
    ///
    /// `/no_think` matters: Qwen3 is a thinking model and emits a `<think>`
    /// block by default, which on a 1.7B model is latency spent on a task that
    /// needs no reasoning. Measured: it still emits empty `<think></think>`
    /// tags, which ``IntentParser`` skips past.
    ///
    /// The examples are doing the real work. A 1.7B model follows a pattern far
    /// more reliably than it follows a description of one.
    static let systemPrompt = """
        /no_think
        You translate requests about a PDF into a single JSON object.
        Output ONLY the JSON. No prose, no explanation, no markdown fence.

        Available tools:
        {"tool":"search","query":"TEXT"}
        {"tool":"count","query":"TEXT"}
        {"tool":"goto","page":N}
        {"tool":"replace","find":"OLD","with":"NEW"}
        {"tool":"rotate","pages":[1,2],"degrees":90}
        {"tool":"delete","pages":[1,2]}
        {"tool":"info"}
        {"tool":"export"}
        {"tool":"ocr"}

        Examples:
        Request: find every mention of invoice
        {"tool":"search","query":"invoice"}

        Request: how many times does Acme appear
        {"tool":"count","query":"Acme"}

        Request: replace every instance of Acme with Globex
        {"tool":"replace","find":"Acme","with":"Globex"}

        Request: rotate page 3 clockwise
        {"tool":"rotate","pages":[3],"degrees":90}

        Request: delete pages 2 and 4
        {"tool":"delete","pages":[2,4]}

        Request: jump to the last page
        {"tool":"goto","page":-1}

        Request: make this searchable
        {"tool":"ocr"}
        """

    /// Locates a cached Hugging Face snapshot.
    ///
    /// Models land in `~/.cache/huggingface/hub/models--<org>--<name>/snapshots/<sha>/`.
    /// Resolving it ourselves keeps the app off the network when the model is
    /// already present, which is the common case.
    static func cachedModelDirectory(for modelID: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
        let snapshots = home
            .appending(path: ".cache/huggingface/hub")
            .appending(path: folder)
            .appending(path: "snapshots")

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: nil
        ) else { return nil }

        // A repo can hold several revisions; any complete one will do, so take
        // the first that actually contains weights.
        return entries.first { entry in
            let contents = try? FileManager.default.contentsOfDirectory(atPath: entry.path)
            return contents?.contains { $0.hasSuffix(".safetensors") } ?? false
        }
    }
}
