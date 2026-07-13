#if os(macOS)
@preconcurrency import AVFoundation
import Foundation
import HeptapodLocalSpeechEngine

public actor HeptapodMacOSSpeechSynthesizerAdapter: HeptapodSpeechSynthesizer {
    public nonisolated let descriptor: HeptapodModelDescriptor

    private let executableURL: URL
    private let outputSampleRate: Int
    private let rateWordsPerMinute: Int?
    private let fileManager: FileManager

    public init(
        descriptor: HeptapodModelDescriptor = .macOSSystemTTS,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/say"),
        outputSampleRate: Int = 24_000,
        rateWordsPerMinute: Int? = 210,
        fileManager: FileManager = .default
    ) {
        self.descriptor = descriptor
        self.executableURL = executableURL
        self.outputSampleRate = outputSampleRate
        self.rateWordsPerMinute = rateWordsPerMinute
        self.fileManager = fileManager
    }

    public func prepare() async throws {
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw HeptapodMacOSSpeechSynthesizerError.missingExecutable(executableURL.path)
        }
    }

    public func synthesize(
        _ text: String,
        languageCode: String,
        voiceID: String?
    ) async throws -> HeptapodSynthesizedSpeech {
        try await prepare()

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else {
            throw HeptapodMacOSSpeechSynthesizerError.emptyText
        }

        let voiceName = try resolveVoiceName(languageCode: languageCode, voiceID: voiceID)
        let workingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("heptapod-system-tts-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: workingDirectory)
        }

        let outputURL = workingDirectory.appendingPathComponent("speech.aiff")
        let process = Process()
        process.executableURL = executableURL
        var arguments = ["-v", voiceName, "-o", outputURL.path]
        if let rateWordsPerMinute {
            arguments.append(contentsOf: ["-r", String(rateWordsPerMinute)])
        }
        arguments.append(trimmedText)
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8) ?? ""
            throw HeptapodMacOSSpeechSynthesizerError.processFailed(
                status: process.terminationStatus,
                output: errorText
            )
        }

        let chunk = try HeptapodSpeechSwiftAudioIO.loadAudioChunk(
            from: outputURL,
            targetSampleRate: outputSampleRate
        )
        guard chunk.pcm16.isEmpty == false else {
            throw HeptapodMacOSSpeechSynthesizerError.emptyOutput(voiceName)
        }
        return HeptapodSynthesizedSpeech(
            pcm16: chunk.pcm16,
            sampleRate: chunk.sampleRate,
            languageCode: languageCode
        )
    }

    private func resolveVoiceName(languageCode: String, voiceID: String?) throws -> String {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let voiceID, voiceID.isEmpty == false {
            if let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
                return voice.name
            }
            if let voice = voices.first(where: { $0.name.caseInsensitiveCompare(voiceID) == .orderedSame }) {
                return voice.name
            }
            throw HeptapodMacOSSpeechSynthesizerError.voiceUnavailable(voiceID)
        }

        let normalized = languageCode.replacingOccurrences(of: "_", with: "-")
        if let voice = voices.first(where: { $0.language.caseInsensitiveCompare(normalized) == .orderedSame }) {
            return voice.name
        }

        let baseLanguage = normalized.split(separator: "-", maxSplits: 1).first.map(String.init) ?? normalized
        if let voice = voices.first(where: {
            $0.language.lowercased().hasPrefix(baseLanguage.lowercased() + "-")
        }) {
            return voice.name
        }
        throw HeptapodMacOSSpeechSynthesizerError.voiceUnavailable(languageCode)
    }
}

public enum HeptapodMacOSSpeechSynthesizerError: LocalizedError, Sendable {
    case emptyText
    case emptyOutput(String)
    case missingExecutable(String)
    case processFailed(status: Int32, output: String)
    case voiceUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .emptyText:
            "macOS speech synthesis received empty text."
        case .emptyOutput(let voice):
            "macOS voice '\(voice)' produced no audio."
        case .missingExecutable(let path):
            "macOS speech synthesis executable is missing at \(path)."
        case .processFailed(let status, let output):
            "macOS speech synthesis failed with status \(status): \(output)"
        case .voiceUnavailable(let value):
            "No installed macOS speech voice matches '\(value)'."
        }
    }
}
#endif
