import Foundation
import HeptapodLocalSpeechEngine

public actor HeptapodChatterboxTTSAdapter: HeptapodSpeechSynthesizer {
    public static let defaultOutputSampleRate = 24_000

    public nonisolated let descriptor: HeptapodModelDescriptor

    private let pythonExecutable: String
    private let scriptURL: URL
    private let voicePromptURL: URL?
    private let device: String?
    private let outputSampleRate: Int
    private let timeoutSeconds: TimeInterval
    private let fileManager: FileManager
    private let usesPersistentWorker: Bool
    private var worker: ChatterboxWorker?

    public init(
        descriptor: HeptapodModelDescriptor = .chatterboxTTS,
        pythonExecutable: String = "python3",
        scriptURL: URL? = nil,
        voicePromptURL: URL? = nil,
        device: String? = nil,
        outputSampleRate: Int = HeptapodChatterboxTTSAdapter.defaultOutputSampleRate,
        timeoutSeconds: TimeInterval = 120,
        usesPersistentWorker: Bool = true,
        fileManager: FileManager = .default
    ) {
        self.descriptor = descriptor
        self.pythonExecutable = pythonExecutable
        self.scriptURL = scriptURL
            ?? ProcessInfo.processInfo.environment["HEPTAPOD_CHATTERBOX_TTS_SCRIPT"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: "Tools/chatterbox_tts.py")
        self.voicePromptURL = voicePromptURL
        self.device = device
        self.outputSampleRate = outputSampleRate
        self.timeoutSeconds = timeoutSeconds
        self.usesPersistentWorker = usesPersistentWorker
        self.fileManager = fileManager
    }

    public func prepare() async throws {
        guard fileManager.fileExists(atPath: scriptURL.path) else {
            throw HeptapodChatterboxTTSError.missingScript(scriptURL.path)
        }
        if let voicePromptURL, fileManager.fileExists(atPath: voicePromptURL.path) == false {
            throw HeptapodChatterboxTTSError.missingVoicePrompt(voicePromptURL.path)
        }
    }

    public func synthesize(
        _ text: String,
        languageCode: String,
        voiceID: String?
    ) async throws -> HeptapodSynthesizedSpeech {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else {
            throw HeptapodChatterboxTTSError.emptyText
        }

        try await prepare()

        let workingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("heptapod-chatterbox-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: workingDirectory)
        }

        let outputURL = workingDirectory.appendingPathComponent("speech.wav")
        if usesPersistentWorker {
            try runChatterboxWorker(
                text: trimmedText,
                languageCode: languageCode,
                voiceID: voiceID,
                outputURL: outputURL
            )
        } else {
            try runChatterboxOneShot(
                text: trimmedText,
                languageCode: languageCode,
                voiceID: voiceID,
                outputURL: outputURL
            )
        }

        let chunk = try HeptapodSpeechSwiftAudioIO.loadAudioChunk(
            from: outputURL,
            targetSampleRate: outputSampleRate
        )
        return HeptapodSynthesizedSpeech(
            pcm16: chunk.pcm16,
            sampleRate: chunk.sampleRate,
            languageCode: languageCode
        )
    }

    private func runChatterboxOneShot(
        text: String,
        languageCode: String,
        voiceID: String?,
        outputURL: URL
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        var arguments = [
            pythonExecutable,
            scriptURL.path,
            "--text", text,
            "--language", languageCode,
            "--output", outputURL.path
        ]
        if let voicePromptURL {
            arguments.append(contentsOf: ["--voice-prompt", voicePromptURL.path])
        }
        if let voiceID, voiceID.isEmpty == false {
            arguments.append(contentsOf: ["--voice-id", voiceID])
        }
        if let device, device.isEmpty == false {
            arguments.append(contentsOf: ["--device", device])
        }
        process.arguments = arguments

        let logDirectory = outputURL.deletingLastPathComponent()
        let stdoutURL = logDirectory.appendingPathComponent("chatterbox.stdout.log")
        let stderrURL = logDirectory.appendingPathComponent("chatterbox.stderr.log")
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                throw HeptapodChatterboxTTSError.timedOut(timeoutSeconds)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let stdoutText = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let stderrText = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""

        guard process.terminationStatus == 0 else {
            throw HeptapodChatterboxTTSError.processFailed(
                status: process.terminationStatus,
                output: [stdoutText, stderrText].joined(separator: "\n")
            )
        }
        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw HeptapodChatterboxTTSError.missingOutput(outputURL.path, [stdoutText, stderrText].joined(separator: "\n"))
        }
    }

    private func runChatterboxWorker(
        text: String,
        languageCode: String,
        voiceID: String?,
        outputURL: URL
    ) throws {
        let worker = try ensureWorker(languageCode: languageCode)
        let request = ChatterboxWorkerRequest(
            id: UUID().uuidString,
            text: text,
            language: languageCode,
            output: outputURL.path,
            voicePrompt: voicePromptURL?.path,
            voiceID: voiceID
        )
        let response = try worker.send(request)
        guard response.ok else {
            throw HeptapodChatterboxTTSError.workerProtocol(response.error ?? "Unknown Chatterbox worker error.")
        }
        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw HeptapodChatterboxTTSError.missingOutput(outputURL.path, try worker.stderrText())
        }
    }

    private func ensureWorker(languageCode: String) throws -> ChatterboxWorker {
        if let worker, worker.isRunning {
            return worker
        }

        let worker = try ChatterboxWorker(
            pythonExecutable: pythonExecutable,
            scriptURL: scriptURL,
            languageCode: languageCode,
            device: device,
            timeoutSeconds: timeoutSeconds,
            fileManager: fileManager
        )
        self.worker = worker
        return worker
    }
}

public enum HeptapodChatterboxTTSError: LocalizedError, Sendable {
    case emptyText
    case missingScript(String)
    case missingVoicePrompt(String)
    case timedOut(TimeInterval)
    case processFailed(status: Int32, output: String)
    case missingOutput(String, String)
    case workerProtocol(String)

    public var errorDescription: String? {
        switch self {
        case .emptyText:
            "Chatterbox TTS received empty text."
        case .missingScript(let path):
            "Chatterbox TTS script is missing at \(path). Pass --tts-script or set HEPTAPOD_CHATTERBOX_TTS_SCRIPT."
        case .missingVoicePrompt(let path):
            "Chatterbox voice prompt file is missing at \(path)."
        case .timedOut(let seconds):
            "Chatterbox TTS timed out after \(Int(seconds)) seconds."
        case .processFailed(let status, let output):
            "Chatterbox TTS process failed with status \(status).\n\(output)"
        case .missingOutput(let path, let output):
            "Chatterbox TTS did not write \(path).\n\(output)"
        case .workerProtocol(let message):
            "Chatterbox TTS worker protocol failed: \(message)"
        }
    }
}

private struct ChatterboxWorkerRequest: Codable {
    let id: String
    let text: String
    let language: String
    let output: String
    let voicePrompt: String?
    let voiceID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case language
        case output
        case voicePrompt = "voice_prompt"
        case voiceID = "voice_id"
    }
}

private struct ChatterboxWorkerResponse: Codable {
    let id: String?
    let ok: Bool
    let output: String?
    let error: String?
}

private struct ChatterboxWorkerReadyResponse: Codable {
    let ready: Bool
    let sampleRate: Int?

    enum CodingKeys: String, CodingKey {
        case ready
        case sampleRate = "sample_rate"
    }
}

private final class ChatterboxWorker {
    private let process: Process
    private let input: FileHandle
    private let lineReader: ChatterboxLineReader
    private let stderr: FileHandle
    private let stderrURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    var isRunning: Bool {
        process.isRunning
    }

    init(
        pythonExecutable: String,
        scriptURL: URL,
        languageCode: String,
        device: String?,
        timeoutSeconds: TimeInterval,
        fileManager: FileManager
    ) throws {
        let logDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("heptapod-chatterbox-worker-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        stderrURL = logDirectory.appendingPathComponent("chatterbox.worker.stderr.log")
        fileManager.createFile(atPath: stderrURL.path, contents: nil)
        stderr = try FileHandle(forWritingTo: stderrURL)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        input = stdinPipe.fileHandleForWriting
        lineReader = ChatterboxLineReader(handle: stdoutPipe.fileHandleForReading)

        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var arguments = [
            pythonExecutable,
            scriptURL.path,
            "--server",
            "--language", languageCode,
            "--multilingual"
        ]
        if let device, device.isEmpty == false {
            arguments.append(contentsOf: ["--device", device])
        }
        process.arguments = arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderr

        try process.run()
        let readyLine = try lineReader.readLine(deadline: Date().addingTimeInterval(timeoutSeconds))
        guard let readyLine else {
            throw HeptapodChatterboxTTSError.processFailed(status: process.terminationStatus, output: try stderrText())
        }
        let ready = try decoder.decode(ChatterboxWorkerReadyResponse.self, from: Data(readyLine.utf8))
        guard ready.ready else {
            throw HeptapodChatterboxTTSError.workerProtocol(readyLine)
        }
    }

    deinit {
        try? input.close()
        try? stderr.close()
        if process.isRunning {
            process.terminate()
        }
    }

    func send(_ request: ChatterboxWorkerRequest) throws -> ChatterboxWorkerResponse {
        guard process.isRunning else {
            throw HeptapodChatterboxTTSError.processFailed(status: process.terminationStatus, output: try stderrText())
        }

        var data = try encoder.encode(request)
        data.append(0x0A)
        input.write(data)

        guard let line = try lineReader.readLine() else {
            throw HeptapodChatterboxTTSError.processFailed(status: process.terminationStatus, output: try stderrText())
        }

        let response = try decoder.decode(ChatterboxWorkerResponse.self, from: Data(line.utf8))
        guard response.id == request.id else {
            throw HeptapodChatterboxTTSError.workerProtocol("Mismatched worker response id: \(line)")
        }
        return response
    }

    func stderrText() throws -> String {
        try stderr.synchronize()
        return (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
    }
}

private final class ChatterboxLineReader {
    private let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
    }

    func readLine(deadline: Date? = nil) throws -> String? {
        var data = Data()
        while true {
            if let deadline, Date() >= deadline {
                throw HeptapodChatterboxTTSError.timedOut(deadline.timeIntervalSinceNow)
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
