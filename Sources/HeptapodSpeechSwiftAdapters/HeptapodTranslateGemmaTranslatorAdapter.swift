import Foundation
import HeptapodLocalSpeechEngine

public actor HeptapodTranslateGemmaTranslatorAdapter: HeptapodTextTranslator {
    public static let defaultModelID = "mlx-community/translategemma-4b-it-4bit"

    public nonisolated let descriptor: HeptapodModelDescriptor

    private let pythonExecutable: String
    private let scriptURL: URL
    private let modelID: String
    private let maximumOutputTokens: Int
    private let timeoutSeconds: TimeInterval
    private let warmsUpPersistentWorker: Bool
    private let fileManager: FileManager
    private var worker: TranslateGemmaWorker?

    public init(
        descriptor: HeptapodModelDescriptor = .translateGemma4B,
        pythonExecutable: String = ".venv-translategemma/bin/python",
        scriptURL: URL? = nil,
        modelID: String = HeptapodTranslateGemmaTranslatorAdapter.defaultModelID,
        maximumOutputTokens: Int = 256,
        timeoutSeconds: TimeInterval = 300,
        warmsUpPersistentWorker: Bool = true,
        fileManager: FileManager = .default
    ) {
        self.descriptor = descriptor
        self.pythonExecutable = pythonExecutable
        self.scriptURL = scriptURL
            ?? ProcessInfo.processInfo.environment["HEPTAPOD_TRANSLATEGEMMA_SCRIPT"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: "Tools/translategemma_mlx_translation.py")
        self.modelID = modelID
        self.maximumOutputTokens = maximumOutputTokens
        self.timeoutSeconds = timeoutSeconds
        self.warmsUpPersistentWorker = warmsUpPersistentWorker
        self.fileManager = fileManager
    }

    public func prepare() async throws {
        guard fileManager.fileExists(atPath: scriptURL.path) else {
            throw HeptapodTranslateGemmaError.missingScript(scriptURL.path)
        }
        guard maximumOutputTokens > 0 else {
            throw HeptapodTranslateGemmaError.invalidMaximumOutputTokens(maximumOutputTokens)
        }
        _ = try ensureWorker()
    }

    public func translate(
        _ text: String,
        sourceLanguageCode: String?,
        targetLanguageCode: String
    ) async throws -> HeptapodTranslatedText {
        let sourceText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sourceText.isEmpty == false else {
            throw HeptapodTranslateGemmaError.emptySourceText
        }
        guard let sourceLanguageCode, sourceLanguageCode.isEmpty == false else {
            throw HeptapodTranslateGemmaError.sourceLanguageRequired
        }
        guard targetLanguageCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw HeptapodTranslateGemmaError.targetLanguageRequired
        }

        try await prepare()
        let request = TranslateGemmaWorkerRequest(
            id: UUID().uuidString,
            text: sourceText,
            sourceLanguage: sourceLanguageCode,
            targetLanguage: targetLanguageCode,
            maximumOutputTokens: maximumOutputTokens
        )
        let response = try ensureWorker().send(request)
        guard response.ok else {
            throw HeptapodTranslateGemmaError.workerProtocol(
                response.error ?? "Unknown TranslateGemma worker error."
            )
        }
        guard let translatedText = response.translation?.trimmingCharacters(in: .whitespacesAndNewlines),
              translatedText.isEmpty == false else {
            throw HeptapodTranslateGemmaError.emptyTranslation
        }

        return HeptapodTranslatedText(
            sourceText: sourceText,
            translatedText: translatedText,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode
        )
    }

    private func ensureWorker() throws -> TranslateGemmaWorker {
        if let worker, worker.isRunning {
            return worker
        }

        let worker = try TranslateGemmaWorker(
            pythonExecutable: pythonExecutable,
            scriptURL: scriptURL,
            modelID: modelID,
            maximumOutputTokens: maximumOutputTokens,
            warmsUp: warmsUpPersistentWorker,
            timeoutSeconds: timeoutSeconds,
            fileManager: fileManager
        )
        self.worker = worker
        return worker
    }
}

public enum HeptapodTranslateGemmaError: LocalizedError, Equatable, Sendable {
    case emptySourceText
    case emptyTranslation
    case sourceLanguageRequired
    case targetLanguageRequired
    case invalidMaximumOutputTokens(Int)
    case missingScript(String)
    case timedOut(TimeInterval)
    case processFailed(status: Int32, output: String)
    case workerProtocol(String)

    public var errorDescription: String? {
        switch self {
        case .emptySourceText:
            "TranslateGemma received empty source text."
        case .emptyTranslation:
            "TranslateGemma returned an empty translation."
        case .sourceLanguageRequired:
            "TranslateGemma requires a source language code."
        case .targetLanguageRequired:
            "TranslateGemma requires a target language code."
        case .invalidMaximumOutputTokens(let count):
            "TranslateGemma maximum output tokens must be positive, not \(count)."
        case .missingScript(let path):
            "TranslateGemma script is missing at \(path). Run Tools/setup_translategemma_mlx.sh."
        case .timedOut(let seconds):
            "TranslateGemma timed out after \(Int(seconds)) seconds."
        case .processFailed(let status, let output):
            "TranslateGemma process failed with status \(status).\n\(output)"
        case .workerProtocol(let message):
            "TranslateGemma worker protocol failed: \(message)"
        }
    }
}

private struct TranslateGemmaWorkerRequest: Codable {
    let id: String
    let text: String
    let sourceLanguage: String
    let targetLanguage: String
    let maximumOutputTokens: Int

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case sourceLanguage = "source_language"
        case targetLanguage = "target_language"
        case maximumOutputTokens = "max_tokens"
    }
}

private struct TranslateGemmaWorkerResponse: Codable {
    let id: String?
    let ok: Bool
    let translation: String?
    let error: String?
}

private struct TranslateGemmaWorkerReadyResponse: Codable {
    let ready: Bool
    let model: String?
}

private final class TranslateGemmaWorker {
    private let process: Process
    private let input: FileHandle
    private let lineReader: TranslateGemmaLineReader
    private let stderr: FileHandle
    private let stderrURL: URL
    private let timeoutSeconds: TimeInterval
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    var isRunning: Bool {
        process.isRunning
    }

    init(
        pythonExecutable: String,
        scriptURL: URL,
        modelID: String,
        maximumOutputTokens: Int,
        warmsUp: Bool,
        timeoutSeconds: TimeInterval,
        fileManager: FileManager
    ) throws {
        self.timeoutSeconds = timeoutSeconds
        let logDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("heptapod-translategemma-worker-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        stderrURL = logDirectory.appendingPathComponent("translategemma.worker.stderr.log")
        fileManager.createFile(atPath: stderrURL.path, contents: nil)
        stderr = try FileHandle(forWritingTo: stderrURL)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        input = stdinPipe.fileHandleForWriting
        lineReader = TranslateGemmaLineReader(handle: stdoutPipe.fileHandleForReading)

        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var arguments = [
            pythonExecutable,
            scriptURL.path,
            "--server",
            "--model", modelID,
            "--max-tokens", String(maximumOutputTokens)
        ]
        if warmsUp {
            arguments.append("--warmup")
        }
        process.arguments = arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderr

        try process.run()
        let readyLine = try lineReader.readLine(deadline: Date().addingTimeInterval(timeoutSeconds))
        guard let readyLine else {
            throw try processFailure()
        }
        let ready = try decoder.decode(TranslateGemmaWorkerReadyResponse.self, from: Data(readyLine.utf8))
        guard ready.ready else {
            throw HeptapodTranslateGemmaError.workerProtocol(readyLine)
        }
    }

    deinit {
        try? input.close()
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        try? stderr.close()
    }

    func send(_ request: TranslateGemmaWorkerRequest) throws -> TranslateGemmaWorkerResponse {
        guard process.isRunning else {
            throw try processFailure()
        }

        var data = try encoder.encode(request)
        data.append(0x0A)
        input.write(data)

        guard let line = try lineReader.readLine(deadline: Date().addingTimeInterval(timeoutSeconds)) else {
            throw try processFailure()
        }
        let response = try decoder.decode(TranslateGemmaWorkerResponse.self, from: Data(line.utf8))
        guard response.id == request.id else {
            throw HeptapodTranslateGemmaError.workerProtocol("Mismatched worker response id: \(line)")
        }
        return response
    }

    private func stderrText() throws -> String {
        try stderr.synchronize()
        return (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
    }

    private func processFailure() throws -> HeptapodTranslateGemmaError {
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        return .processFailed(status: process.terminationStatus, output: try stderrText())
    }
}

private final class TranslateGemmaLineReader {
    private let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
    }

    func readLine(deadline: Date) throws -> String? {
        var data = Data()
        while true {
            if Date() >= deadline {
                throw HeptapodTranslateGemmaError.timedOut(max(0, deadline.timeIntervalSinceNow))
            }

            let byte = handle.readData(ofLength: 1)
            if byte.isEmpty {
                return data.isEmpty ? nil : String(data: data, encoding: .utf8)
            }
            if byte[byte.startIndex] == 0x0A {
                return String(data: data, encoding: .utf8)
            }
            data.append(byte)
        }
    }
}
