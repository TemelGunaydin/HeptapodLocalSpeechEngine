import Foundation
import HeptapodLocalSpeechEngine
import HeptapodSpeechSwiftAdapters

@main
struct HeptapodLiveSpeechDemo {
    static func main() async {
        do {
            let options = try DemoOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.shouldPrintHelp {
                printUsage()
                return
            }
            if options.shouldPrintCacheStatus {
                try printCacheStatus()
                return
            }

            if options.selectedLiveSourceCount > 1 {
                throw DemoError.multipleAudioSources
            }

            if options.usesRealModels && options.usesMicrophone == false && options.usesSystemAudio == false && options.audioPath == nil {
                throw DemoError.realModeRequiresAudioSource
            }

            if options.audioPath != nil && options.usesRealModels == false {
                throw DemoError.audioFileRequiresRealMode
            }
            if (options.usesMicrophone || options.usesSystemAudio) && options.usesRealModels == false {
                throw DemoError.liveAudioRequiresRealMode
            }

            let targetLanguageCode = options.targetLanguageCode ?? (options.usesRealModels ? "es" : "tr")
            let pipeline = try makePipeline(options: options)

            try await pipeline.prepare()
            printHeader(options: options, targetLanguageCode: targetLanguageCode)

            if let audioPath = options.audioPath {
                try await runAudioFileDemo(
                    pipeline: pipeline,
                    audioPath: audioPath,
                    targetLanguageCode: targetLanguageCode,
                    shouldPlayOutput: options.shouldPlayOutput,
                    outputDirectory: options.outputDirectory,
                    usesSentenceBuffering: options.usesSentenceBuffering
                )
            } else if options.usesMicrophone {
                try await runMicrophoneDemo(
                    pipeline: pipeline,
                    targetLanguageCode: targetLanguageCode,
                    durationSeconds: options.durationSeconds,
                    shouldPlayOutput: options.shouldPlayOutput,
                    outputDirectory: options.outputDirectory,
                    usesSentenceBuffering: options.usesSentenceBuffering
                )
            } else if options.usesSystemAudio {
                try await runSystemAudioDemo(
                    pipeline: pipeline,
                    targetLanguageCode: targetLanguageCode,
                    durationSeconds: options.durationSeconds,
                    shouldPlayOutput: options.shouldPlayOutput,
                    outputDirectory: options.outputDirectory,
                    usesSentenceBuffering: options.usesSentenceBuffering
                )
            } else if options.isInteractive {
                try await runInteractiveDemo(
                    pipeline: pipeline,
                    targetLanguageCode: targetLanguageCode,
                    shouldSpeak: options.shouldSpeak
                )
            } else {
                try await runScriptedDemo(
                    pipeline: pipeline,
                    targetLanguageCode: targetLanguageCode,
                    shouldSpeak: options.shouldSpeak
                )
            }
        } catch {
            fputs("Demo failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func makePipeline(options: DemoOptions) throws -> HeptapodSpeechToSpeechPipeline {
        if options.usesRealModels {
            return try HeptapodSpeechSwiftAdapterFactory.makePipeline(
                configuration: options.pipelineConfiguration,
                chatterboxPythonExecutable: options.ttsPythonExecutable,
                chatterboxScriptURL: options.ttsScriptPath.map(URL.init(fileURLWithPath:)),
                chatterboxVoicePromptURL: options.ttsVoicePromptPath.map(URL.init(fileURLWithPath:)),
                chatterboxDevice: options.ttsDevice
            )
        }

        return try HeptapodSpeechToSpeechPipeline(
            configuration: HeptapodModelCatalog.starterPipeline,
            vad: PreviewVoiceActivityDetector(),
            recognizer: PreviewSpeechRecognizer(),
            translator: PreviewTextTranslator(),
            synthesizer: PreviewSpeechSynthesizer()
        )
    }

    private static func printHeader(options: DemoOptions, targetLanguageCode: String) {
        print("""
        Heptapod Live Speech Demo

        Mode: \(options.usesRealModels ? "real speech-swift adapters" : "preview adapters")
        ASR:  \(HeptapodModelDescriptor.qwenASRCompact.displayName)
        MT:   \(HeptapodModelDescriptor.madladTranslator.displayName)
        TTS:  \(options.ttsDescriptor.displayName)
        Flow: audio chunk source -> live session -> VAD -> ASR -> MT -> TTS -> playback sink
        Source: \(options.sourceDescription)
        Target: \(targetLanguageCode)
        Speak: \(options.shouldSpeak || options.shouldPlayOutput ? "on" : "off")
        Translation timing: \(options.usesSentenceBuffering ? "sentence/pause buffered" : "every chunk")

        """)
    }

    private static func printUsage() {
        print("""
        Usage:
          swift run HeptapodLiveSpeechDemo
          swift run HeptapodLiveSpeechDemo -- --interactive
          swift run HeptapodLiveSpeechDemo -- --cache-status
          swift run HeptapodLiveSpeechDemo -- --real --audio /path/to/input.wav --to es --output-dir /tmp/heptapod-live
          swift run HeptapodLiveSpeechDemo -- --real --microphone --to es --duration 10 --play-output
          swift run HeptapodLiveSpeechDemo -- --real --system-audio --to tr --play-output
          swift run HeptapodLiveSpeechDemo -- --real --system-audio --to tr --tts chatterbox --play-output

        Options:
          --interactive       Type preview text segments on stdin.
          --real              Use real speech-swift adapters. Requires --audio, --microphone, or --system-audio.
          --audio <path>      Stream an audio file through the live session.
          --microphone        Capture live microphone audio chunks.
          --system-audio      Capture macOS system audio with ScreenCaptureKit.
          --duration <sec>    Stop microphone capture after this many seconds.
          --to <code>         Target language. Default: tr for preview, es for real mode.
          --tts <name>        Real mode TTS backend: kokoro or chatterbox. Default: kokoro.
          --tts-script <path> Chatterbox bridge script. Default: Tools/chatterbox_tts.py.
          --tts-python <name> Python executable for Chatterbox. Default: python3.
          --tts-device <name> Chatterbox torch device: auto, cpu, mps, or cuda.
          --tts-voice-prompt <path>
                              Optional reference WAV for Chatterbox voice cloning.
          --chunk-translation
                              Translate every audio chunk instead of waiting for sentence/pause endpointing.
          --output-dir <path> Write synthesized live segments as WAV files.
          --speak             Preview mode only: speak translated text with /usr/bin/say.
          --play-output       Real live mode: play synthesized speech with AVAudioEngine.
          --cache-status      Print starter model cache paths and cached sizes.
          --help              Show this help.
        """)
    }

    private static func printCacheStatus() throws {
        let statuses = try HeptapodSpeechSwiftModelCache.starterModelStatuses()
        print("Heptapod starter model cache status\n")

        for status in statuses {
            print("\(status.descriptor.displayName)")
            print("  Model: \(status.modelID)")
            print("  Cached: \(status.isCached ? "yes" : "no")")
            print("  Size: \(status.cachedSize.displayText)")
            print("  Path: \(status.cacheDirectory.path)")
        }
    }

    private static func runScriptedDemo(
        pipeline: HeptapodSpeechToSpeechPipeline,
        targetLanguageCode: String,
        shouldSpeak: Bool
    ) async throws {
        let source = ScriptedChunkSource(scriptedChunks: [
            ScriptedChunk(text: "", delay: 0.8),
            ScriptedChunk(text: "hello", delay: 1.0),
            ScriptedChunk(text: "how are you", delay: 1.0),
            ScriptedChunk(text: "we are testing live speech to speech", delay: 1.0)
        ])
        try await runLiveSession(
            pipeline: pipeline,
            chunks: source.chunks(),
            targetLanguageCode: targetLanguageCode,
            shouldSpeak: shouldSpeak
        )

        print("\nDone. Use `swift run HeptapodLiveSpeechDemo -- --interactive` to type live segments.")
    }

    private static func runInteractiveDemo(
        pipeline: HeptapodSpeechToSpeechPipeline,
        targetLanguageCode: String,
        shouldSpeak: Bool
    ) async throws {
        print("Type source-language speech segments. Empty line simulates silence. Type `quit` to exit.\n")
        let source = InteractiveTextChunkSource()
        try await runLiveSession(
            pipeline: pipeline,
            chunks: source.chunks(),
            targetLanguageCode: targetLanguageCode,
            shouldSpeak: shouldSpeak
        )
    }

    private static func runMicrophoneDemo(
        pipeline: HeptapodSpeechToSpeechPipeline,
        targetLanguageCode: String,
        durationSeconds: Double?,
        shouldPlayOutput: Bool,
        outputDirectory: String?,
        usesSentenceBuffering: Bool
    ) async throws {
        print("Listening. Stop with Ctrl+C\(durationSeconds.map { " or wait \($0)s" } ?? "").\n")
        let source = HeptapodAVAudioMicrophoneSource(maximumDurationSeconds: durationSeconds)
        let fileSink = outputDirectory.map { HeptapodWAVFilePlaybackSink(outputDirectory: URL(fileURLWithPath: $0)) }
        try await runLiveSession(
            pipeline: pipeline,
            chunks: source.chunks(),
            targetLanguageCode: targetLanguageCode,
            playbackSink: makePlaybackSink(shouldPlayOutput: shouldPlayOutput, fileSink: fileSink),
            usesSentenceBuffering: usesSentenceBuffering,
            shouldSpeak: false
        )
        try await printWrittenFiles(fileSink)
    }

    private static func runSystemAudioDemo(
        pipeline: HeptapodSpeechToSpeechPipeline,
        targetLanguageCode: String,
        durationSeconds: Double?,
        shouldPlayOutput: Bool,
        outputDirectory: String?,
        usesSentenceBuffering: Bool
    ) async throws {
        #if os(macOS)
        print("""
        Capturing macOS system audio. Start YouTube/browser playback now.
        Stop with Ctrl+C\(durationSeconds.map { " or wait \($0)s" } ?? "").

        """)
        let source = HeptapodScreenCaptureSystemAudioSource(maximumDurationSeconds: durationSeconds)
        let fileSink = outputDirectory.map { HeptapodWAVFilePlaybackSink(outputDirectory: URL(fileURLWithPath: $0)) }
        try await runLiveSession(
            pipeline: pipeline,
            chunks: source.chunks(),
            targetLanguageCode: targetLanguageCode,
            playbackSink: makePlaybackSink(shouldPlayOutput: shouldPlayOutput, fileSink: fileSink),
            usesSentenceBuffering: usesSentenceBuffering,
            shouldSpeak: false
        )
        try await printWrittenFiles(fileSink)
        #else
        throw DemoError.systemAudioRequiresMacOS
        #endif
    }

    private static func runAudioFileDemo(
        pipeline: HeptapodSpeechToSpeechPipeline,
        audioPath: String,
        targetLanguageCode: String,
        shouldPlayOutput: Bool,
        outputDirectory: String?,
        usesSentenceBuffering: Bool
    ) async throws {
        let source = HeptapodAudioFileChunkSource(url: URL(fileURLWithPath: audioPath))
        let fileSink = outputDirectory.map { HeptapodWAVFilePlaybackSink(outputDirectory: URL(fileURLWithPath: $0)) }
        try await runLiveSession(
            pipeline: pipeline,
            chunks: source.chunks(),
            targetLanguageCode: targetLanguageCode,
            playbackSink: makePlaybackSink(shouldPlayOutput: shouldPlayOutput, fileSink: fileSink),
            usesSentenceBuffering: usesSentenceBuffering,
            shouldSpeak: false
        )
        try await printWrittenFiles(fileSink)
    }

    private static func makePlaybackSink(
        shouldPlayOutput: Bool,
        fileSink: HeptapodWAVFilePlaybackSink?
    ) -> (any HeptapodSpeechPlaybackSink)? {
        var sinks: [any HeptapodSpeechPlaybackSink] = []
        if let fileSink {
            sinks.append(fileSink)
        }
        if shouldPlayOutput {
            sinks.append(HeptapodAVAudioPlaybackSink())
        }

        if sinks.isEmpty {
            return nil
        }
        if sinks.count == 1 {
            return sinks[0]
        }
        return CompositePlaybackSink(sinks: sinks)
    }

    private static func printWrittenFiles(_ sink: HeptapodWAVFilePlaybackSink?) async throws {
        guard let sink else {
            return
        }

        let files = await sink.writtenFiles()
        for file in files {
            print("  Output: \(file.path)")
        }
    }

    private static func runLiveSession(
        pipeline: HeptapodSpeechToSpeechPipeline,
        chunks: AsyncThrowingStream<HeptapodAudioChunk, Error>,
        targetLanguageCode: String,
        playbackSink: (any HeptapodSpeechPlaybackSink)? = nil,
        usesSentenceBuffering: Bool = false,
        shouldSpeak: Bool
    ) async throws {
        let session = HeptapodLiveSpeechSession(
            pipeline: pipeline,
            sourceLanguageCode: "en",
            targetLanguageCode: targetLanguageCode,
            playbackSink: playbackSink
        )
        let events = usesSentenceBuffering
            ? await session.runSentenceBuffered(chunks: chunks)
            : await session.run(chunks: chunks)

        for try await event in events {
            switch event {
            case .segmentStarted(let index):
                print("Segment \(index)")
            case .silenceSkipped:
                print("  VAD: silence, skipped")
            case .result(_, let result):
                printResult(result)
                if shouldSpeak {
                    speak(result.translation.translatedText)
                }
            case .playbackCompleted:
                print("  Playback: completed")
            }
        }
    }

    private static func printResult(_ result: HeptapodSpeechToSpeechResult) {
        print("  VAD: speech")
        print("  ASR: \(result.transcript.text)")
        print("  MT:  \(result.translation.translatedText)")
        print("  TTS: \(result.speech.pcm16.count) PCM bytes at \(result.speech.sampleRate) Hz")
    }

    private static func speak(_ text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [text]
        try? process.run()
        process.waitUntilExit()
    }
}

private struct DemoOptions {
    let isInteractive: Bool
    let usesRealModels: Bool
    let usesMicrophone: Bool
    let usesSystemAudio: Bool
    let shouldSpeak: Bool
    let shouldPlayOutput: Bool
    let shouldPrintHelp: Bool
    let shouldPrintCacheStatus: Bool
    let usesSentenceBuffering: Bool
    let targetLanguageCode: String?
    let ttsBackend: DemoTTSBackend
    let ttsScriptPath: String?
    let ttsPythonExecutable: String
    let ttsDevice: String?
    let ttsVoicePromptPath: String?
    let durationSeconds: Double?
    let audioPath: String?
    let outputDirectory: String?

    init(arguments: [String]) throws {
        var isInteractive = false
        var usesRealModels = false
        var usesMicrophone = false
        var usesSystemAudio = false
        var shouldSpeak = false
        var shouldPlayOutput = false
        var shouldPrintHelp = false
        var shouldPrintCacheStatus = false
        var usesSentenceBuffering = true
        var targetLanguageCode: String?
        var ttsBackend = DemoTTSBackend.kokoro
        var ttsScriptPath: String?
        var ttsPythonExecutable = "python3"
        var ttsDevice: String?
        var ttsVoicePromptPath: String?
        var durationSeconds: Double?
        var audioPath: String?
        var outputDirectory: String?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--":
                break
            case "--interactive":
                isInteractive = true
            case "--real":
                usesRealModels = true
            case "--audio":
                audioPath = try Self.value(after: argument, in: arguments, at: &index)
            case "--microphone":
                usesMicrophone = true
            case "--system-audio":
                usesSystemAudio = true
            case "--speak":
                shouldSpeak = true
            case "--play-output":
                shouldPlayOutput = true
            case "--cache-status":
                shouldPrintCacheStatus = true
            case "--chunk-translation":
                usesSentenceBuffering = false
            case "--to":
                targetLanguageCode = try Self.value(after: argument, in: arguments, at: &index)
            case "--tts":
                let rawValue = try Self.value(after: argument, in: arguments, at: &index)
                guard let backend = DemoTTSBackend(rawValue: rawValue.lowercased()) else {
                    throw DemoError.invalidTTSBackend(rawValue)
                }
                ttsBackend = backend
            case "--tts-script":
                ttsScriptPath = try Self.value(after: argument, in: arguments, at: &index)
            case "--tts-python":
                ttsPythonExecutable = try Self.value(after: argument, in: arguments, at: &index)
            case "--tts-device":
                let rawValue = try Self.value(after: argument, in: arguments, at: &index)
                guard ["auto", "cpu", "mps", "cuda"].contains(rawValue) else {
                    throw DemoError.invalidTTSDevice(rawValue)
                }
                ttsDevice = rawValue == "auto" ? nil : rawValue
            case "--tts-voice-prompt":
                ttsVoicePromptPath = try Self.value(after: argument, in: arguments, at: &index)
            case "--output-dir":
                outputDirectory = try Self.value(after: argument, in: arguments, at: &index)
            case "--duration":
                let rawValue = try Self.value(after: argument, in: arguments, at: &index)
                guard let value = Double(rawValue), value > 0 else {
                    throw DemoError.invalidDuration(rawValue)
                }
                durationSeconds = value
            case "--help", "-h":
                shouldPrintHelp = true
            default:
                throw DemoError.unknownArgument(argument)
            }
            index += 1
        }

        self.isInteractive = isInteractive
        self.usesRealModels = usesRealModels
        self.usesMicrophone = usesMicrophone
        self.usesSystemAudio = usesSystemAudio
        self.shouldSpeak = shouldSpeak
        self.shouldPlayOutput = shouldPlayOutput
        self.shouldPrintHelp = shouldPrintHelp
        self.shouldPrintCacheStatus = shouldPrintCacheStatus
        self.usesSentenceBuffering = usesSentenceBuffering
        self.targetLanguageCode = targetLanguageCode
        self.ttsBackend = ttsBackend
        self.ttsScriptPath = ttsScriptPath
        self.ttsPythonExecutable = ttsPythonExecutable
        self.ttsDevice = ttsDevice
        self.ttsVoicePromptPath = ttsVoicePromptPath
        self.durationSeconds = durationSeconds
        self.audioPath = audioPath
        self.outputDirectory = outputDirectory
    }

    private static func value(after option: String, in arguments: [String], at index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw DemoError.missingValue(option)
        }
        index = valueIndex
        return arguments[valueIndex]
    }

    var sourceDescription: String {
        if let audioPath {
            return "audio file: \(audioPath)"
        }
        if usesMicrophone {
            return "microphone"
        }
        if usesSystemAudio {
            return "macOS system audio"
        }
        if isInteractive {
            return "stdin"
        }
        return "scripted"
    }

    var selectedLiveSourceCount: Int {
        (audioPath == nil ? 0 : 1) + (usesMicrophone ? 1 : 0) + (usesSystemAudio ? 1 : 0)
    }

    var pipelineConfiguration: HeptapodPipelineConfiguration {
        HeptapodPipelineConfiguration(
            speechRecognitionModelID: HeptapodModelDescriptor.qwenASRCompact.id,
            textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
            speechSynthesisModelID: ttsDescriptor.id,
            voiceActivityModelID: HeptapodModelDescriptor.sileroVAD.id
        )
    }

    var ttsDescriptor: HeptapodModelDescriptor {
        switch ttsBackend {
        case .kokoro:
            HeptapodModelDescriptor.kokoroTTS
        case .chatterbox:
            HeptapodModelDescriptor.chatterboxTTS
        }
    }
}

private enum DemoTTSBackend: String {
    case kokoro
    case chatterbox
}

private struct CompositePlaybackSink: HeptapodSpeechPlaybackSink {
    let sinks: [any HeptapodSpeechPlaybackSink]

    func play(_ speech: HeptapodSynthesizedSpeech) async throws {
        for sink in sinks {
            try await sink.play(speech)
        }
    }
}

private enum DemoError: LocalizedError {
    case invalidDuration(String)
    case invalidTTSBackend(String)
    case invalidTTSDevice(String)
    case audioFileRequiresRealMode
    case liveAudioRequiresRealMode
    case missingValue(String)
    case multipleAudioSources
    case realModeRequiresAudioSource
    case systemAudioRequiresMacOS
    case unknownArgument(String)

    var errorDescription: String? {
        switch self {
        case .invalidDuration(let value):
            "Invalid duration: \(value)."
        case .invalidTTSBackend(let value):
            "Invalid TTS backend: \(value). Use kokoro or chatterbox."
        case .invalidTTSDevice(let value):
            "Invalid TTS device: \(value). Use auto, cpu, mps, or cuda."
        case .audioFileRequiresRealMode:
            "Audio file live mode requires --real."
        case .liveAudioRequiresRealMode:
            "Microphone and system-audio live modes require --real."
        case .missingValue(let option):
            "Missing value after \(option)."
        case .multipleAudioSources:
            "Choose only one live audio source: --audio, --microphone, or --system-audio."
        case .realModeRequiresAudioSource:
            "Real live mode requires --audio, --microphone, or --system-audio."
        case .systemAudioRequiresMacOS:
            "System audio capture requires macOS."
        case .unknownArgument(let argument):
            "Unknown argument: \(argument)."
        }
    }
}

private struct ScriptedChunk {
    let text: String
    let delay: Double

    var audioChunk: HeptapodAudioChunk {
        HeptapodAudioChunk(pcm16: Data(text.utf8), sampleRate: 16_000)
    }
}

private struct ScriptedChunkSource: HeptapodAudioChunkSource {
    let scriptedChunks: [ScriptedChunk]

    func chunks() -> AsyncThrowingStream<HeptapodAudioChunk, Error> {
        let chunks = scriptedChunks

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for chunk in chunks {
                        try Task.checkCancellation()
                        try await Task.sleep(for: .seconds(chunk.delay))
                        continuation.yield(chunk.audioChunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

private struct InteractiveTextChunkSource: HeptapodAudioChunkSource {
    func chunks() -> AsyncThrowingStream<HeptapodAudioChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    print("> ", terminator: "")
                    guard let line = readLine(strippingNewline: true) else {
                        break
                    }
                    if line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "quit" {
                        break
                    }
                    continuation.yield(ScriptedChunk(text: line, delay: 0).audioChunk)
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

private struct PreviewVoiceActivityDetector: HeptapodVoiceActivityDetector {
    let descriptor = HeptapodModelDescriptor.sileroVAD

    func prepare() async throws {}

    func containsSpeech(_ chunk: HeptapodAudioChunk) async throws -> Bool {
        String(decoding: chunk.pcm16, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
    }
}

private struct PreviewSpeechRecognizer: HeptapodSpeechRecognizer {
    let descriptor = HeptapodModelDescriptor.qwenASRCompact

    func prepare() async throws {}

    func transcribe(_ chunk: HeptapodAudioChunk, languageHint: String?) async throws -> HeptapodTranscriptSegment? {
        let text = String(decoding: chunk.pcm16, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else {
            return nil
        }
        return HeptapodTranscriptSegment(text: text, languageCode: languageHint, isFinal: true)
    }

    func finish(languageHint: String?) async throws -> HeptapodTranscriptSegment? {
        nil
    }

    func reset() async {}
}

private struct PreviewTextTranslator: HeptapodTextTranslator {
    let descriptor = HeptapodModelDescriptor.madladTranslator

    private let phrasebook = [
        "hello": "merhaba",
        "how are you": "nasilsin",
        "we are testing live speech to speech": "canli konusmadan konusmaya ceviriyi test ediyoruz",
        "good morning": "gunaydin",
        "thank you": "tesekkur ederim"
    ]

    func prepare() async throws {}

    func translate(
        _ text: String,
        sourceLanguageCode: String?,
        targetLanguageCode: String
    ) async throws -> HeptapodTranslatedText {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let translated = phrasebook[normalized] ?? "[\(targetLanguageCode)] \(text)"
        return HeptapodTranslatedText(
            sourceText: text,
            translatedText: translated,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode
        )
    }
}

private struct PreviewSpeechSynthesizer: HeptapodSpeechSynthesizer {
    let descriptor = HeptapodModelDescriptor.kokoroTTS

    func prepare() async throws {}

    func synthesize(
        _ text: String,
        languageCode: String,
        voiceID: String?
    ) async throws -> HeptapodSynthesizedSpeech {
        let samplesPerCharacter = 240
        let byteCount = max(2, text.count * samplesPerCharacter)
        let pcm = Data(repeating: 0, count: byteCount)
        return HeptapodSynthesizedSpeech(pcm16: pcm, sampleRate: 24_000, languageCode: languageCode)
    }
}
