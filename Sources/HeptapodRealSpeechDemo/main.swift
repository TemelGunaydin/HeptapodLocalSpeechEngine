import Foundation
import HeptapodLocalSpeechEngine
import HeptapodSpeechSwiftAdapters

@main
struct HeptapodRealSpeechDemo {
    static func main() async {
        do {
            let options = try DemoOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.shouldPrintHelp {
                printUsage()
                return
            }

            guard let audioPath = options.audioPath else {
                printUsage()
                Foundation.exit(2)
            }

            let startedAt = Date()
            printHeader(options: options)

            print("Loading input audio: \(audioPath)")
            let audioChunk = try HeptapodSpeechSwiftAudioIO.loadAudioChunk(
                from: URL(fileURLWithPath: audioPath),
                targetSampleRate: 16_000
            )

            let timingRecorder = DemoTimingRecorder()
            let vad = TimingVoiceActivityDetector(
                base: HeptapodSileroVADAdapter(),
                recorder: timingRecorder
            )
            let recognizer = TimingSpeechRecognizer(
                base: HeptapodQwen3ASRAdapter(),
                recorder: timingRecorder
            )
            let translator = TimingTextTranslator(
                base: HeptapodMADLADTranslatorAdapter(),
                recorder: timingRecorder
            )
            let synthesizer = TimingSpeechSynthesizer(
                base: HeptapodKokoroTTSAdapter(defaultVoiceID: options.voiceID),
                recorder: timingRecorder,
                languageCodeOverride: options.ttsLanguageCode
            )
            let pipeline = try HeptapodSpeechToSpeechPipeline(
                configuration: HeptapodModelCatalog.starterPipeline,
                vad: vad,
                recognizer: recognizer,
                translator: translator,
                synthesizer: synthesizer
            )

            print("Preparing VAD, ASR, translation, and TTS models; first run may download weights...")
            try await pipeline.prepare()

            print("Processing through HeptapodSpeechToSpeechPipeline...")
            guard let result = try await pipeline.processDetailed(
                audioChunk,
                sourceLanguageCode: options.sourceLanguageCode,
                targetLanguageCode: options.targetLanguageCode,
                voiceID: options.voiceID
            ) else {
                throw DemoError.noSpeechDetected
            }
            let stageTimings = await timingRecorder.snapshot()
            let transcriptText = result.transcript.text
            let translatedText = result.translation.translatedText
            let speech = result.speech

            try HeptapodSpeechSwiftAudioIO.writeWAV(result.speech, to: options.outputURL)

            print("VAD [\(format(seconds: stageTimings.vadInferenceSeconds))]: speech")
            print("ASR [\(format(seconds: stageTimings.asrInferenceSeconds))]: \(transcriptText)")
            print("MT  [\(format(seconds: stageTimings.translationInferenceSeconds))]: \(translatedText)")
            print("TTS [\(format(seconds: stageTimings.ttsInferenceSeconds))]: \(options.outputURL.path)")

            let totalDuration = Date().timeIntervalSince(startedAt)
            let report = DemoReport(
                createdAt: ISO8601DateFormatter().string(from: Date()),
                inputPath: audioPath,
                outputPath: options.outputURL.path,
                sourceLanguageCode: options.sourceLanguageCode,
                targetLanguageCode: options.targetLanguageCode,
                ttsLanguageCode: options.ttsLanguageCode,
                voiceID: options.voiceID,
                models: DemoModels(
                    vad: HeptapodSileroVADAdapter.defaultModelID,
                    asr: HeptapodQwen3ASRAdapter.defaultModelID,
                    translation: HeptapodMADLADTranslatorAdapter.defaultModelID,
                    tts: HeptapodKokoroTTSAdapter.defaultModelID
                ),
                transcript: transcriptText,
                translation: translatedText,
                audio: DemoAudioMetrics(
                    inputSamples: audioChunk.pcm16.count / MemoryLayout<Int16>.size,
                    inputSampleRate: 16_000,
                    inputDurationSeconds: Double(audioChunk.pcm16.count / MemoryLayout<Int16>.size) / 16_000,
                    outputSamples: speech.pcm16.count / MemoryLayout<Int16>.size,
                    outputSampleRate: speech.sampleRate,
                    outputDurationSeconds: Double(speech.pcm16.count / MemoryLayout<Int16>.size) / Double(speech.sampleRate)
                ),
                timings: DemoTimings(
                    vadModelLoadSeconds: stageTimings.vadModelLoadSeconds,
                    vadInferenceSeconds: stageTimings.vadInferenceSeconds,
                    asrModelLoadSeconds: stageTimings.asrModelLoadSeconds,
                    asrInferenceSeconds: stageTimings.asrInferenceSeconds,
                    translationModelLoadSeconds: stageTimings.translationModelLoadSeconds,
                    translationInferenceSeconds: stageTimings.translationInferenceSeconds,
                    ttsModelLoadSeconds: stageTimings.ttsModelLoadSeconds,
                    ttsInferenceSeconds: stageTimings.ttsInferenceSeconds,
                    pipelineInferenceSeconds: stageTimings.pipelineInferenceSeconds,
                    totalSeconds: totalDuration
                )
            )
            try report.write(to: options.reportURL)

            print("Report: \(options.reportURL.path)")
            print("Done [\(format(seconds: totalDuration))]")
        } catch {
            fputs("Real demo failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func printHeader(options: DemoOptions) {
        print("""
        Heptapod Real Speech Demo

        ASR: Qwen3-ASR via speech-swift
        MT:  MADLAD-400 via speech-swift
        TTS: Kokoro-82M via speech-swift
        Flow: audio file -> VAD -> ASR -> MT -> TTS -> WAV
        Source hint: \(options.sourceLanguageCode ?? "auto")
        Target: \(options.targetLanguageCode)
        TTS language: \(options.ttsLanguageCode)
        Output: \(options.outputURL.path)
        Report: \(options.reportURL.path)

        """)
    }

    private static func printUsage() {
        print("""
        Usage:
          swift run HeptapodRealSpeechDemo -- --audio /path/to/input.wav --from en --to es --tts-language es --output /tmp/heptapod-es.wav

        Options:
          --audio <path>       Input audio file. WAV, M4A, MP3, and CAF are expected by the ASR runtime.
          --from <code>        Source language hint for ASR. Default: en
          --to <code>          Target language code for translation. Default: tr
          --tts-language <code> Kokoro phonemizer language. Supported: en, fr, es, ja, zh, hi, pt, it. Default: en
          --voice <id>         Kokoro voice ID. Default: af_heart
          --output <path>      Output WAV path. Default: /tmp/heptapod-real-output.wav
          --report <path>      JSON latency/detail report path. Default: /tmp/heptapod-real-report.json
          --help               Show this help.

        First run downloads model weights from Hugging Face and caches them locally.
        """)
    }

    private static func elapsed(since date: Date) -> String {
        format(seconds: Date().timeIntervalSince(date))
    }

    private static func format(seconds: TimeInterval) -> String {
        String(format: "%.2fs", seconds)
    }
}

private struct DemoOptions {
    let audioPath: String?
    let sourceLanguageCode: String?
    let targetLanguageCode: String
    let ttsLanguageCode: String
    let voiceID: String
    let outputURL: URL
    let reportURL: URL
    let shouldPrintHelp: Bool

    init(arguments: [String]) throws {
        var audioPath: String?
        var sourceLanguageCode = "en"
        var targetLanguageCode = "tr"
        var ttsLanguageCode = "en"
        var voiceID = "af_heart"
        var outputPath = "/tmp/heptapod-real-output.wav"
        var reportPath = "/tmp/heptapod-real-report.json"
        var shouldPrintHelp = false

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--":
                break
            case "--audio":
                audioPath = try Self.value(after: argument, in: arguments, at: &index)
            case "--from":
                sourceLanguageCode = try Self.value(after: argument, in: arguments, at: &index)
            case "--to":
                targetLanguageCode = try Self.value(after: argument, in: arguments, at: &index)
            case "--tts-language":
                ttsLanguageCode = try Self.value(after: argument, in: arguments, at: &index)
            case "--voice":
                voiceID = try Self.value(after: argument, in: arguments, at: &index)
            case "--output":
                outputPath = try Self.value(after: argument, in: arguments, at: &index)
            case "--report":
                reportPath = try Self.value(after: argument, in: arguments, at: &index)
            case "--help", "-h":
                shouldPrintHelp = true
            default:
                throw DemoError.unknownArgument(argument)
            }
            index += 1
        }

        self.audioPath = audioPath
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
        self.ttsLanguageCode = ttsLanguageCode
        self.voiceID = voiceID
        self.outputURL = URL(fileURLWithPath: outputPath)
        self.reportURL = URL(fileURLWithPath: reportPath)
        self.shouldPrintHelp = shouldPrintHelp
    }

    private static func value(after option: String, in arguments: [String], at index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw DemoError.missingValue(option)
        }
        index = valueIndex
        return arguments[valueIndex]
    }
}

private struct DemoReport: Codable {
    let createdAt: String
    let inputPath: String
    let outputPath: String
    let sourceLanguageCode: String?
    let targetLanguageCode: String
    let ttsLanguageCode: String
    let voiceID: String
    let models: DemoModels
    let transcript: String
    let translation: String
    let audio: DemoAudioMetrics
    let timings: DemoTimings

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }
}

private struct DemoModels: Codable {
    let vad: String
    let asr: String
    let translation: String
    let tts: String
}

private struct DemoAudioMetrics: Codable {
    let inputSamples: Int
    let inputSampleRate: Int
    let inputDurationSeconds: Double
    let outputSamples: Int
    let outputSampleRate: Int
    let outputDurationSeconds: Double
}

private struct DemoTimings: Codable {
    let vadModelLoadSeconds: Double
    let vadInferenceSeconds: Double
    let asrModelLoadSeconds: Double
    let asrInferenceSeconds: Double
    let translationModelLoadSeconds: Double
    let translationInferenceSeconds: Double
    let ttsModelLoadSeconds: Double
    let ttsInferenceSeconds: Double
    let pipelineInferenceSeconds: Double
    let totalSeconds: Double
}

private enum DemoError: LocalizedError {
    case emptyTranscript
    case noSpeechDetected
    case missingValue(String)
    case unknownArgument(String)

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            "ASR returned an empty transcript."
        case .noSpeechDetected:
            "VAD did not detect speech in the input audio."
        case .missingValue(let option):
            "Missing value after \(option)."
        case .unknownArgument(let argument):
            "Unknown argument: \(argument)."
        }
    }
}

private enum DemoTimingStage: Sendable {
    case vad
    case asr
    case translation
    case tts
}

private struct DemoStageTimings: Sendable {
    let vadModelLoadSeconds: Double
    let vadInferenceSeconds: Double
    let asrModelLoadSeconds: Double
    let asrInferenceSeconds: Double
    let translationModelLoadSeconds: Double
    let translationInferenceSeconds: Double
    let ttsModelLoadSeconds: Double
    let ttsInferenceSeconds: Double

    var pipelineInferenceSeconds: Double {
        vadInferenceSeconds + asrInferenceSeconds + translationInferenceSeconds + ttsInferenceSeconds
    }
}

private actor DemoTimingRecorder {
    private var vadModelLoadSeconds = 0.0
    private var vadInferenceSeconds = 0.0
    private var asrModelLoadSeconds = 0.0
    private var asrInferenceSeconds = 0.0
    private var translationModelLoadSeconds = 0.0
    private var translationInferenceSeconds = 0.0
    private var ttsModelLoadSeconds = 0.0
    private var ttsInferenceSeconds = 0.0

    func recordPrepare(stage: DemoTimingStage, duration: TimeInterval) {
        switch stage {
        case .vad:
            vadModelLoadSeconds += duration
        case .asr:
            asrModelLoadSeconds += duration
        case .translation:
            translationModelLoadSeconds += duration
        case .tts:
            ttsModelLoadSeconds += duration
        }
    }

    func recordInference(stage: DemoTimingStage, duration: TimeInterval) {
        switch stage {
        case .vad:
            vadInferenceSeconds += duration
        case .asr:
            asrInferenceSeconds += duration
        case .translation:
            translationInferenceSeconds += duration
        case .tts:
            ttsInferenceSeconds += duration
        }
    }

    func snapshot() -> DemoStageTimings {
        DemoStageTimings(
            vadModelLoadSeconds: vadModelLoadSeconds,
            vadInferenceSeconds: vadInferenceSeconds,
            asrModelLoadSeconds: asrModelLoadSeconds,
            asrInferenceSeconds: asrInferenceSeconds,
            translationModelLoadSeconds: translationModelLoadSeconds,
            translationInferenceSeconds: translationInferenceSeconds,
            ttsModelLoadSeconds: ttsModelLoadSeconds,
            ttsInferenceSeconds: ttsInferenceSeconds
        )
    }
}

private actor TimingVoiceActivityDetector: HeptapodVoiceActivityDetector {
    nonisolated let descriptor: HeptapodModelDescriptor

    private let base: any HeptapodVoiceActivityDetector
    private let recorder: DemoTimingRecorder

    init(base: any HeptapodVoiceActivityDetector, recorder: DemoTimingRecorder) {
        self.base = base
        self.recorder = recorder
        self.descriptor = base.descriptor
    }

    func prepare() async throws {
        let startedAt = Date()
        try await base.prepare()
        await recorder.recordPrepare(stage: .vad, duration: Date().timeIntervalSince(startedAt))
    }

    func containsSpeech(_ chunk: HeptapodAudioChunk) async throws -> Bool {
        let startedAt = Date()
        let result = try await base.containsSpeech(chunk)
        await recorder.recordInference(stage: .vad, duration: Date().timeIntervalSince(startedAt))
        return result
    }
}

private actor TimingSpeechRecognizer: HeptapodSpeechRecognizer {
    nonisolated let descriptor: HeptapodModelDescriptor

    private let base: any HeptapodSpeechRecognizer
    private let recorder: DemoTimingRecorder

    init(base: any HeptapodSpeechRecognizer, recorder: DemoTimingRecorder) {
        self.base = base
        self.recorder = recorder
        self.descriptor = base.descriptor
    }

    func prepare() async throws {
        let startedAt = Date()
        try await base.prepare()
        await recorder.recordPrepare(stage: .asr, duration: Date().timeIntervalSince(startedAt))
    }

    func transcribe(_ chunk: HeptapodAudioChunk, languageHint: String?) async throws -> HeptapodTranscriptSegment? {
        let startedAt = Date()
        let result = try await base.transcribe(chunk, languageHint: languageHint)
        await recorder.recordInference(stage: .asr, duration: Date().timeIntervalSince(startedAt))
        return result
    }

    func finish(languageHint: String?) async throws -> HeptapodTranscriptSegment? {
        try await base.finish(languageHint: languageHint)
    }

    func reset() async {
        await base.reset()
    }
}

private actor TimingTextTranslator: HeptapodTextTranslator {
    nonisolated let descriptor: HeptapodModelDescriptor

    private let base: any HeptapodTextTranslator
    private let recorder: DemoTimingRecorder

    init(base: any HeptapodTextTranslator, recorder: DemoTimingRecorder) {
        self.base = base
        self.recorder = recorder
        self.descriptor = base.descriptor
    }

    func prepare() async throws {
        let startedAt = Date()
        try await base.prepare()
        await recorder.recordPrepare(stage: .translation, duration: Date().timeIntervalSince(startedAt))
    }

    func translate(
        _ text: String,
        sourceLanguageCode: String?,
        targetLanguageCode: String
    ) async throws -> HeptapodTranslatedText {
        let startedAt = Date()
        let result = try await base.translate(
            text,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode
        )
        await recorder.recordInference(stage: .translation, duration: Date().timeIntervalSince(startedAt))
        return result
    }
}

private actor TimingSpeechSynthesizer: HeptapodSpeechSynthesizer {
    nonisolated let descriptor: HeptapodModelDescriptor

    private let base: any HeptapodSpeechSynthesizer
    private let recorder: DemoTimingRecorder
    private let languageCodeOverride: String?

    init(
        base: any HeptapodSpeechSynthesizer,
        recorder: DemoTimingRecorder,
        languageCodeOverride: String?
    ) {
        self.base = base
        self.recorder = recorder
        self.languageCodeOverride = languageCodeOverride
        self.descriptor = base.descriptor
    }

    func prepare() async throws {
        let startedAt = Date()
        try await base.prepare()
        await recorder.recordPrepare(stage: .tts, duration: Date().timeIntervalSince(startedAt))
    }

    func synthesize(
        _ text: String,
        languageCode: String,
        voiceID: String?
    ) async throws -> HeptapodSynthesizedSpeech {
        let startedAt = Date()
        let result = try await base.synthesize(
            text,
            languageCode: languageCodeOverride ?? languageCode,
            voiceID: voiceID
        )
        await recorder.recordInference(stage: .tts, duration: Date().timeIntervalSince(startedAt))
        return result
    }
}
