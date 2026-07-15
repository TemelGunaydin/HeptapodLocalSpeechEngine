import Foundation
import HeptapodLocalSpeechEngine

public actor HeptapodMossTTSNanoAdapter: HeptapodSpeechSynthesizer {
    public nonisolated let descriptor: HeptapodModelDescriptor

    private let pythonExecutable: String
    private let scriptURL: URL
    private let voicePromptURL: URL?
    private let defaultVoice: String
    private let modelDirectoryURL: URL?
    private let cpuThreads: Int
    private let timeoutSeconds: TimeInterval
    private let fileManager: FileManager
    private var worker: MossTTSNanoWorker?

    public init(
        descriptor: HeptapodModelDescriptor = .mossTTSNano,
        pythonExecutable: String = ".venv-moss-tts-nano/bin/python",
        scriptURL: URL? = nil,
        voicePromptURL: URL? = nil,
        defaultVoice: String = "Ava",
        modelDirectoryURL: URL? = nil,
        cpuThreads: Int = 8,
        timeoutSeconds: TimeInterval = 600,
        fileManager: FileManager = .default
    ) {
        self.descriptor = descriptor
        self.pythonExecutable = pythonExecutable
        self.scriptURL = scriptURL
            ?? ProcessInfo.processInfo.environment["HEPTAPOD_MOSS_TTS_SCRIPT"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: "Tools/moss_tts_nano_bridge.py")
        self.voicePromptURL = voicePromptURL
        self.defaultVoice = defaultVoice
        self.modelDirectoryURL = modelDirectoryURL
        self.cpuThreads = max(1, cpuThreads)
        self.timeoutSeconds = timeoutSeconds
        self.fileManager = fileManager
    }

    public func prepare() async throws {
        guard fileManager.fileExists(atPath: scriptURL.path) else {
            throw HeptapodMossTTSNanoError.missingScript(scriptURL.path)
        }
        if let voicePromptURL, fileManager.fileExists(atPath: voicePromptURL.path) == false {
            throw HeptapodMossTTSNanoError.missingVoicePrompt(voicePromptURL.path)
        }
        _ = try ensureWorker()
    }

    public func synthesize(
        _ text: String,
        languageCode: String,
        voiceID: String?
    ) async throws -> HeptapodSynthesizedSpeech {
        var pcm16 = Data()
        var sampleRate: Int?
        let stream = await synthesizeStream(text, languageCode: languageCode, voiceID: voiceID)
        for try await chunk in stream {
            if let sampleRate, sampleRate != chunk.sampleRate {
                throw HeptapodMossTTSNanoError.inconsistentSampleRate(sampleRate, chunk.sampleRate)
            }
            sampleRate = chunk.sampleRate
            pcm16.append(chunk.pcm16)
        }
        guard let sampleRate, pcm16.isEmpty == false else {
            throw HeptapodMossTTSNanoError.emptyOutput
        }
        return HeptapodSynthesizedSpeech(
            pcm16: pcm16,
            sampleRate: sampleRate,
            languageCode: languageCode
        )
    }

    public func synthesizeStream(
        _ text: String,
        languageCode: String,
        voiceID: String?
    ) async -> AsyncThrowingStream<HeptapodSynthesizedSpeech, Error> {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pair = AsyncThrowingStream<HeptapodSynthesizedSpeech, Error>.makeStream()
        let task = Task {
            do {
                guard trimmedText.isEmpty == false else {
                    throw HeptapodMossTTSNanoError.emptyText
                }
                try await prepare()
                try Task.checkCancellation()
                let request = MossTTSNanoWorkerRequest(
                    id: UUID().uuidString,
                    text: trimmedText,
                    language: languageCode,
                    voicePrompt: voicePromptURL?.path,
                    voiceID: voiceID
                )
                try runWorker(request) { speech in
                    try Task.checkCancellation()
                    pair.continuation.yield(speech)
                }
                pair.continuation.finish()
            } catch {
                pair.continuation.finish(throwing: error)
            }
        }
        pair.continuation.onTermination = { _ in
            task.cancel()
        }
        return pair.stream
    }

    private func runWorker(
        _ request: MossTTSNanoWorkerRequest,
        onSpeech: (HeptapodSynthesizedSpeech) throws -> Void
    ) throws {
        let worker = try ensureWorker()
        do {
            try worker.stream(request) { event in
                guard event.event == "audio" else { return }
                guard let encodedPCM = event.pcm16,
                      let pcm16 = Data(base64Encoded: encodedPCM),
                      pcm16.isEmpty == false,
                      let sampleRate = event.sampleRate
                else {
                    throw HeptapodMossTTSNanoError.workerProtocol("Invalid audio event from MOSS worker.")
                }
                try onSpeech(
                    HeptapodSynthesizedSpeech(
                        pcm16: pcm16,
                        sampleRate: sampleRate,
                        languageCode: request.language
                    )
                )
            }
        } catch {
            self.worker = nil
            throw error
        }
    }

    private func ensureWorker() throws -> MossTTSNanoWorker {
        if let worker, worker.isRunning {
            return worker
        }
        let worker = try MossTTSNanoWorker(
            pythonExecutable: pythonExecutable,
            scriptURL: scriptURL,
            defaultVoice: defaultVoice,
            modelDirectoryURL: modelDirectoryURL,
            cpuThreads: cpuThreads,
            timeoutSeconds: timeoutSeconds,
            fileManager: fileManager
        )
        self.worker = worker
        return worker
    }
}

public enum HeptapodMossTTSNanoError: LocalizedError, Sendable {
    case emptyOutput
    case emptyText
    case inconsistentSampleRate(Int, Int)
    case missingScript(String)
    case missingVoicePrompt(String)
    case processFailed(status: Int32, output: String)
    case timedOut(TimeInterval)
    case workerProtocol(String)

    public var errorDescription: String? {
        switch self {
        case .emptyOutput:
            "MOSS-TTS-Nano produced no audio."
        case .emptyText:
            "MOSS-TTS-Nano received empty text."
        case .inconsistentSampleRate(let expected, let actual):
            "MOSS-TTS-Nano changed sample rate from \(expected) Hz to \(actual) Hz during one stream."
        case .missingScript(let path):
            "MOSS-TTS-Nano bridge script is missing at \(path). Run Tools/setup_moss_tts_nano.sh."
        case .missingVoicePrompt(let path):
            "MOSS-TTS-Nano voice prompt is missing at \(path)."
        case .processFailed(let status, let output):
            "MOSS-TTS-Nano worker failed with status \(status):\n\(output)"
        case .timedOut(let seconds):
            "MOSS-TTS-Nano worker timed out after \(Int(seconds)) seconds."
        case .workerProtocol(let message):
            "MOSS-TTS-Nano worker protocol failed: \(message)"
        }
    }
}

private struct MossTTSNanoWorkerRequest: Codable {
    let id: String
    let text: String
    let language: String
    let voicePrompt: String?
    let voiceID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case language
        case voicePrompt = "voice_prompt"
        case voiceID = "voice_id"
    }
}

private struct MossTTSNanoWorkerEvent: Decodable {
    let id: String?
    let event: String
    let sampleRate: Int?
    let pcm16: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id
        case event
        case sampleRate = "sample_rate"
        case pcm16
        case error
    }
}

private struct MossTTSNanoWorkerReady: Decodable {
    let ready: Bool
    let sampleRate: Int?
    let voices: [String]?

    enum CodingKeys: String, CodingKey {
        case ready
        case sampleRate = "sample_rate"
        case voices
    }
}

private final class MossTTSNanoWorker {
    private let process: Process
    private let input: FileHandle
    private let lineReader: MossTTSNanoLineReader
    private let stderr: FileHandle
    private let stderrURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    var isRunning: Bool { process.isRunning }

    init(
        pythonExecutable: String,
        scriptURL: URL,
        defaultVoice: String,
        modelDirectoryURL: URL?,
        cpuThreads: Int,
        timeoutSeconds: TimeInterval,
        fileManager: FileManager
    ) throws {
        let logDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("heptapod-moss-tts-worker-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        stderrURL = logDirectory.appendingPathComponent("moss-tts.worker.stderr.log")
        fileManager.createFile(atPath: stderrURL.path, contents: nil)
        stderr = try FileHandle(forWritingTo: stderrURL)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        input = stdinPipe.fileHandleForWriting
        lineReader = MossTTSNanoLineReader(handle: stdoutPipe.fileHandleForReading)

        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var arguments = [
            pythonExecutable,
            scriptURL.path,
            "--server",
            "--voice", defaultVoice,
            "--cpu-threads", String(cpuThreads)
        ]
        if let modelDirectoryURL {
            arguments.append(contentsOf: ["--model-dir", modelDirectoryURL.path])
        }
        process.arguments = arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderr

        try process.run()
        guard let readyLine = try lineReader.readLine(deadline: Date().addingTimeInterval(timeoutSeconds)) else {
            throw try processFailure()
        }
        let ready = try decoder.decode(MossTTSNanoWorkerReady.self, from: Data(readyLine.utf8))
        guard ready.ready, ready.sampleRate != nil else {
            throw HeptapodMossTTSNanoError.workerProtocol(readyLine)
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

    func stream(
        _ request: MossTTSNanoWorkerRequest,
        onEvent: (MossTTSNanoWorkerEvent) throws -> Void
    ) throws {
        guard process.isRunning else {
            throw try processFailure()
        }
        var data = try encoder.encode(request)
        data.append(0x0A)
        input.write(data)

        while true {
            guard let line = try lineReader.readLine() else {
                throw try processFailure()
            }
            let event = try decoder.decode(MossTTSNanoWorkerEvent.self, from: Data(line.utf8))
            guard event.id == request.id else {
                throw HeptapodMossTTSNanoError.workerProtocol("Mismatched worker response id: \(line)")
            }
            switch event.event {
            case "audio":
                try onEvent(event)
            case "done":
                return
            case "error":
                throw HeptapodMossTTSNanoError.workerProtocol(event.error ?? "Unknown worker error.")
            default:
                throw HeptapodMossTTSNanoError.workerProtocol("Unknown worker event: \(line)")
            }
        }
    }

    private func stderrText() throws -> String {
        try stderr.synchronize()
        return (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
    }

    private func processFailure() throws -> HeptapodMossTTSNanoError {
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        return .processFailed(status: process.terminationStatus, output: try stderrText())
    }
}

private final class MossTTSNanoLineReader {
    private let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
    }

    func readLine(deadline: Date? = nil) throws -> String? {
        var data = Data()
        while true {
            if let deadline, Date() >= deadline {
                throw HeptapodMossTTSNanoError.timedOut(max(0, deadline.timeIntervalSinceNow))
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
