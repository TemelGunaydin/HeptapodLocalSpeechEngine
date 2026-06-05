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

    public init(
        descriptor: HeptapodModelDescriptor = .chatterboxTTS,
        pythonExecutable: String = "python3",
        scriptURL: URL? = nil,
        voicePromptURL: URL? = nil,
        device: String? = nil,
        outputSampleRate: Int = HeptapodChatterboxTTSAdapter.defaultOutputSampleRate,
        timeoutSeconds: TimeInterval = 120,
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
        try runChatterbox(
            text: trimmedText,
            languageCode: languageCode,
            voiceID: voiceID,
            outputURL: outputURL
        )

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

    private func runChatterbox(
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
}

public enum HeptapodChatterboxTTSError: LocalizedError, Sendable {
    case emptyText
    case missingScript(String)
    case missingVoicePrompt(String)
    case timedOut(TimeInterval)
    case processFailed(status: Int32, output: String)
    case missingOutput(String, String)

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
        }
    }
}
