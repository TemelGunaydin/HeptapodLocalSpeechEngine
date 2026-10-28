import Darwin
import Foundation
import HeptapodLocalSpeechEngine

/// Native 24 kHz PCM streaming from Wite Tech's Turkish Pocket TTS model on CPU.
public actor HeptapodPocketTurkishTTSAdapter: HeptapodSpeechSynthesizer {
    public nonisolated let descriptor = HeptapodModelDescriptor.pocketTurkishTTS
    public static let voices = ["female_1", "female_2", "female_3", "male_1", "male_2", "male_3"]
    private let pythonExecutable: String
    private let scriptURL: URL
    private let modelDirectoryURL: URL?
    private let defaultVoice: String
    private let offlineMode: Bool
    private let timeoutSeconds: TimeInterval
    private var worker: PocketTurkishWorker?

    public init(
        pythonExecutable: String = ".venv-pocket-tts/bin/python",
        scriptURL: URL? = nil,
        modelDirectoryURL: URL? = nil,
        defaultVoice: String = "female_2",
        offlineMode: Bool = false,
        timeoutSeconds: TimeInterval = 300
    ) {
        self.pythonExecutable = pythonExecutable
        self.scriptURL = scriptURL ?? URL(fileURLWithPath: "Tools/pocket_turkish_tts.py")
        self.modelDirectoryURL = modelDirectoryURL
        self.defaultVoice = defaultVoice
        self.offlineMode = offlineMode
        self.timeoutSeconds = timeoutSeconds
    }

    public func prepare() async throws {
        guard Self.voices.contains(defaultVoice) else { throw HeptapodPocketTTSError.invalidVoice(defaultVoice) }
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw HeptapodPocketTTSError.worker("Timeout must be finite and positive.")
        }
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw HeptapodPocketTTSError.worker("Missing \(scriptURL.path). Run Tools/setup_pocket_tts.sh.")
        }
        _ = try ensureWorker()
    }

    public func prepare(languageCode: String?) async throws {
        if let languageCode { try validateLanguage(languageCode) }
        try await prepare()
    }

    public func synthesize(_ text: String, languageCode: String, voiceID: String?) async throws -> HeptapodSynthesizedSpeech {
        var pcm16 = Data()
        for try await chunk in await synthesizeStream(text, languageCode: languageCode, voiceID: voiceID) {
            pcm16.append(chunk.pcm16)
        }
        try Task.checkCancellation()
        guard !pcm16.isEmpty else { throw HeptapodPocketTTSError.worker("Model returned no audio.") }
        return HeptapodSynthesizedSpeech(pcm16: pcm16, sampleRate: 24_000, languageCode: languageCode)
    }

    public func synthesizeStream(
        _ text: String, languageCode: String, voiceID: String?
    ) async -> AsyncThrowingStream<HeptapodSynthesizedSpeech, Error> {
        let pair = AsyncThrowingStream<HeptapodSynthesizedSpeech, Error>.makeStream()
        // The pipeline limits pending utterances. Preserve every PCM chunk in the current utterance.
        let task = Task {
            do {
                try validateLanguage(languageCode)
                let voice = voiceID ?? defaultVoice
                guard Self.voices.contains(voice) else { throw HeptapodPocketTTSError.invalidVoice(voice) }
                let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw HeptapodPocketTTSError.worker("Text is empty.") }
                try await prepare()
                try Task.checkCancellation()
                do {
                    try ensureWorker().stream(text: text, language: languageCode, voice: voice) { pcm in
                        try Task.checkCancellation()
                        pair.continuation.yield(HeptapodSynthesizedSpeech(
                            pcm16: pcm, sampleRate: 24_000, languageCode: languageCode
                        ))
                    }
                } catch {
                    // Discard pending responses after cancellation or a protocol failure.
                    worker = nil
                    throw error
                }
                pair.continuation.finish()
            } catch {
                pair.continuation.finish(throwing: error)
            }
        }
        pair.continuation.onTermination = { _ in task.cancel() }
        return pair.stream
    }

    private func validateLanguage(_ code: String) throws {
        guard code.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first == "tr" else {
            throw HeptapodPocketTTSError.unsupportedLanguage(code)
        }
    }

    private func ensureWorker() throws -> PocketTurkishWorker {
        if let worker, worker.isRunning { return worker }
        let worker = try PocketTurkishWorker(
            python: pythonExecutable, script: scriptURL, modelDirectory: modelDirectoryURL,
            voice: defaultVoice, offline: offlineMode, timeout: timeoutSeconds
        )
        self.worker = worker
        return worker
    }
}

public enum HeptapodPocketTTSError: LocalizedError, Sendable {
    case unsupportedLanguage(String)
    case invalidVoice(String)
    case timedOut(TimeInterval)
    case worker(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let language): "Pocket TTS Turkish supports Turkish only, not \(language)."
        case .invalidVoice(let voice): "Unknown Pocket voice: \(voice). Choose \(HeptapodPocketTurkishTTSAdapter.voices.joined(separator: ", "))."
        case .timedOut(let seconds): "Pocket TTS timed out after \(seconds) seconds."
        case .worker(let message): "Pocket TTS: \(message)"
        }
    }
}

private final class PocketTurkishWorker {
    private let process = Process()
    private let input: FileHandle
    private let output: FileHandle
    private let errorFile: FileHandle
    private let errorURL: URL
    private let timeout: TimeInterval
    private var buffered = Data()
    private var launched = false
    var isRunning: Bool { process.isRunning }

    init(python: String, script: URL, modelDirectory: URL?, voice: String, offline: Bool, timeout: TimeInterval) throws {
        self.timeout = timeout
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("heptapod-pocket-worker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        errorURL = directory.appendingPathComponent("stderr.log")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        errorFile = try FileHandle(forWritingTo: errorURL)
        let stdin = Pipe(), stdout = Pipe()
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        // A worker exit during a write should throw EPIPE instead of terminating the app.
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var arguments = [python, script.path, "--server", "--voice", voice]
        if let modelDirectory { arguments += ["--model-dir", modelDirectory.path] }
        if offline { arguments.append("--offline") }
        process.arguments = arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = errorFile
        do {
            try process.run()
            launched = true
            try stdin.fileHandleForReading.close()
            try stdout.fileHandleForWriting.close()
            let ready = try readResponse(deadline: ProcessInfo.processInfo.systemUptime + timeout)
            guard ready["ready"] as? Bool == true, ready["sample_rate"] as? Int == 24_000 else {
                throw HeptapodPocketTTSError.worker("Invalid startup response.")
            }
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    private func stop() {
        try? input.close()
        if process.isRunning { process.terminate() }
        if launched { process.waitUntilExit() }
        try? output.close()
        try? errorFile.close()
    }

    func stream(text: String, language: String, voice: String, onAudio: (Data) throws -> Void) throws {
        try Task.checkCancellation()
        let id = UUID().uuidString
        var data = try JSONSerialization.data(withJSONObject: ["id": id, "text": text, "language": language, "voice_id": voice])
        data.append(0x0A)
        try input.write(contentsOf: data)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var receivedAudio = false
        while true {
            let response = try readResponse(deadline: deadline)
            guard response["id"] as? String == id else { throw HeptapodPocketTTSError.worker("Mismatched response ID.") }
            switch response["event"] as? String {
            case "audio":
                guard response["sample_rate"] as? Int == 24_000,
                      let encoded = response["pcm16"] as? String, let pcm = Data(base64Encoded: encoded),
                      !pcm.isEmpty, pcm.count.isMultiple(of: 2) else {
                    throw HeptapodPocketTTSError.worker("Invalid PCM event.")
                }
                try onAudio(pcm)
                receivedAudio = true
            case "done":
                guard receivedAudio else { throw HeptapodPocketTTSError.worker("Model returned no audio.") }
                return
            case "error": throw HeptapodPocketTTSError.worker(response["error"] as? String ?? "Generation failed.")
            default: throw HeptapodPocketTTSError.worker("Unknown worker event.")
            }
        }
    }

    private func readResponse(deadline: TimeInterval) throws -> [String: Any] {
        while true {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw HeptapodPocketTTSError.timedOut(timeout) }
            if let newline = buffered.firstIndex(of: 0x0A) {
                let line = buffered[..<newline]
                let response = try JSONSerialization.jsonObject(with: line)
                buffered.removeSubrange(...newline)
                guard let response = response as? [String: Any] else { throw HeptapodPocketTTSError.worker("Expected a JSON object.") }
                return response
            }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let status = poll(&descriptor, 1, 50)
            if status < 0 {
                if errno == EINTR { continue }
                throw HeptapodPocketTTSError.worker("Cannot poll worker output.")
            }
            if status == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(output.fileDescriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                let error = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? "Worker exited."
                throw HeptapodPocketTTSError.worker("Worker exited. \(error)")
            }
            buffered.append(contentsOf: bytes.prefix(count))
        }
    }
}
