import Foundation
import HeptapodLocalSpeechEngine
import Testing
@testable import HeptapodLiveSpeechDemo

@Suite(.timeLimit(.minutes(1)))
struct HeptapodLiveTraceTimingTests {
    @Test(arguments: [false, true])
    func repeatedCaptureIndexKeepsFirstOutputLatency(withPlayback: Bool) async throws {
        let firstSynthesisStarted = TraceTimingGate()
        let secondTranslationStarted = TraceTimingGate()
        let pipeline = try HeptapodSpeechToSpeechPipeline(
            configuration: HeptapodPipelineConfiguration(
                speechRecognitionModelID: HeptapodModelDescriptor.qwenASRCompact.id,
                textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
                speechSynthesisModelID: HeptapodModelDescriptor.kokoroTTS.id
            ),
            recognizer: TraceTimingRecognizer(),
            translator: TraceTimingTranslator(secondStarted: secondTranslationStarted),
            synthesizer: TraceTimingSynthesizer(
                firstStarted: firstSynthesisStarted,
                releaseFirst: secondTranslationStarted
            )
        )
        let source = AsyncThrowingStream<HeptapodAudioChunk, Error>.makeStream()
        let producer = Task {
            do {
                source.continuation.yield(HeptapodAudioChunk(
                    pcm16: Data("First complete sentence. Second".utf8),
                    sampleRate: 16_000
                ))
                try await firstSynthesisStarted.wait()
                // Separate the two accepted outputs in wall time. Expectations
                // use the trace's actual timestamps, not the scheduler's timing.
                try await Task.sleep(for: .milliseconds(150))
                source.continuation.finish()
            } catch {
                source.continuation.finish(throwing: error)
            }
        }
        defer { producer.cancel() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heptapod-trace-timing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("trace.jsonl")

        try await HeptapodLiveSpeechDemo.runLiveSession(
            pipeline: pipeline,
            chunks: source.stream,
            sourceLanguageCode: "en",
            targetLanguageCode: "tr",
            playbackSink: withPlayback ? TraceTimingPlaybackSink() : nil,
            endpointing: HeptapodSentenceEndpointingConfiguration(
                flushOnTerminalPunctuation: true,
                minimumWordsForPunctuationEndpoint: 2
            ),
            usesSentenceBuffering: true,
            tracePath: path.path,
            shouldSpeak: false
        )
        let events = try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(TraceTimingRow.self, from: Data($0.utf8))
        }
        let accepted = events.filter { $0.event == "output_queued" }
        let firstAudio = events.filter { $0.event == "tts_first_audio" }
        let results = events.filter { $0.event == "result_ready" }
        #expect(accepted.count == 2)
        #expect(accepted.map(\.index) == [1, 1])
        #expect(firstAudio.count == 2)
        #expect(accepted.map(\.outputID) == [1, 2])
        #expect(firstAudio.map(\.outputID) == [1, 2])
        #expect(results.map(\.outputID) == [1, 2])
        #expect(results.map(\.transcriptText) == ["First complete sentence.", "Second"])
        let firstAccepted = try #require(accepted.first)
        let firstReady = try #require(firstAudio.first)
        let latency = try #require(firstReady.firstAudioLatencySeconds)
        #expect(abs(latency - (firstReady.elapsedSeconds - firstAccepted.elapsedSeconds)) < 0.02)
        for id in 1...2 {
            let output = events.filter { $0.outputID == id }
            let queued = try #require(output.first { $0.event == "output_queued" })
            let ready = try #require(output.first { $0.event == "result_ready" })
            let outputLatency = try #require(ready.outputLatencySeconds)
            #expect(abs(outputLatency - (ready.elapsedSeconds - queued.elapsedSeconds)) < 0.02)
            if withPlayback {
                let started = try #require(output.first { $0.event == "playback_started" })
                let completed = try #require(output.first { $0.event == "playback_completed" })
                let duration = try #require(completed.playbackDurationSeconds)
                #expect(abs(duration - (completed.elapsedSeconds - started.elapsedSeconds)) < 0.02)
            }
        }
        #expect(events.last?.event == "run_finished")
    }

    @Test
    func overlappingStagesKeepEachOutputAndReleaseFinishedTimings() {
        var timings = LiveEventTimings()
        _ = timings.record(.segmentStarted(index: 1), at: 0)
        _ = timings.record(.outputQueued(index: 1, backlog: 1), at: 10)
        _ = timings.record(.outputQueued(index: 1, backlog: 2), at: 20)
        let firstMT = timings.record(.translationStarted(index: 1), at: 21)
        #expect(firstMT.outputID == 1)
        #expect(firstMT.queueWaitSeconds == 11)
        #expect(timings.record(.translationCompleted(index: 1), at: 22).stageDurationSeconds == 1)
        #expect(timings.record(.synthesisStarted(index: 1), at: 23).queueWaitSeconds == 1)
        _ = timings.record(.playbackQueued(index: 1, backlog: 1), at: 24)
        #expect(timings.record(.translationStarted(index: 1), at: 25).queueWaitSeconds == 5)
        _ = timings.record(.translationCompleted(index: 1), at: 26)
        // Capture continues while translation, synthesis, and playback overlap.
        _ = timings.record(.segmentStarted(index: 2), at: 26)
        let firstAudio = timings.record(.synthesisAudioReady(index: 1), at: 27)
        #expect(firstAudio.outputID == 1)
        #expect(firstAudio.firstAudioLatencySeconds == 17)
        #expect(firstAudio.stageDurationSeconds == 4)
        let firstResult = timings.record(.result(index: 1, Self.result), at: 28)
        #expect(firstResult.outputID == 1)
        #expect(firstResult.resultLatencySeconds == 28)
        #expect(firstResult.outputLatencySeconds == 18)
        #expect(firstResult.stageDurationSeconds == 5)
        #expect(timings.record(.synthesisStarted(index: 1), at: 29).queueWaitSeconds == 3)
        let firstPlayback = timings.record(.playbackStarted(index: 1), at: 30)
        #expect(firstPlayback.outputID == 1)
        #expect(firstPlayback.queueWaitSeconds == 3)
        #expect(firstPlayback.playbackLatencySeconds == 2)
        _ = timings.record(.playbackQueued(index: 1, backlog: 2), at: 31)
        let secondAudio = timings.record(.synthesisAudioReady(index: 1), at: 32)
        #expect(secondAudio.outputID == 2)
        #expect(secondAudio.firstAudioLatencySeconds == 12)
        #expect(secondAudio.stageDurationSeconds == 3)
        _ = timings.record(.result(index: 1, Self.result), at: 33)
        let firstCompleted = timings.record(.playbackCompleted(index: 1), at: 39)
        #expect(firstCompleted.outputID == 1)
        #expect(firstCompleted.playbackDurationSeconds == 9)
        #expect(firstCompleted.playbackLatencySeconds == 11)
        #expect(timings.pendingOutputCount == 1)
        let secondPlayback = timings.record(.playbackStarted(index: 1), at: 40)
        #expect(secondPlayback.outputID == 2)
        #expect(secondPlayback.queueWaitSeconds == 8)
        #expect(secondPlayback.playbackLatencySeconds == 7)
        #expect(timings.record(.playbackCompleted(index: 1), at: 45).playbackDurationSeconds == 5)
        #expect(timings.pendingOutputCount == 0)
    }

    @Test
    func streamingPlaybackMayCompleteBeforeItsResult() {
        var timings = LiveEventTimings()
        _ = timings.record(.segmentStarted(index: 1), at: 0)
        _ = timings.record(.outputQueued(index: 1, backlog: 1), at: 1)
        _ = timings.record(.translationStarted(index: 1), at: 2)
        _ = timings.record(.translationCompleted(index: 1), at: 3)
        _ = timings.record(.synthesisStarted(index: 1), at: 4)
        _ = timings.record(.playbackQueued(index: 1, backlog: 1), at: 5)
        _ = timings.record(.synthesisAudioReady(index: 1), at: 6)
        #expect(timings.record(.playbackStarted(index: 1), at: 7).playbackLatencySeconds == nil)
        let completed = timings.record(.playbackCompleted(index: 1), at: 8)
        #expect(completed.playbackDurationSeconds == 1)
        #expect(completed.playbackLatencySeconds == nil)
        #expect(timings.pendingOutputCount == 1)
        let result = timings.record(.result(index: 1, Self.result), at: 9)
        #expect(result.outputID == 1)
        #expect(result.stageDurationSeconds == 5)
        #expect(result.outputLatencySeconds == 8)
        #expect(timings.pendingOutputCount == 0)
    }

    @Test
    func textOnlyLatencyStartsAtAcceptedOutputRatherThanLatestASRDelta() {
        var timings = LiveEventTimings()
        _ = timings.record(.segmentStarted(index: 1), at: 0)
        _ = timings.record(.transcript(index: 1, Self.result.transcript), at: 1)
        _ = timings.record(.outputQueued(index: 1, backlog: 1), at: 2)
        _ = timings.record(.translationStarted(index: 1), at: 3)
        _ = timings.record(.transcript(index: 1, Self.result.transcript), at: 4)
        _ = timings.record(.translationCompleted(index: 1), at: 5)
        let translated = timings.record(.translation(index: 1, HeptapodLiveTranslationResult(
            transcript: Self.result.transcript,
            translation: Self.result.translation
        )), at: 6)
        #expect(translated.outputID == 1)
        #expect(translated.outputLatencySeconds == 4)
        #expect(timings.pendingOutputCount == 0)
    }

    private static var result: HeptapodSpeechToSpeechResult {
        HeptapodSpeechToSpeechResult(
            transcript: HeptapodTranscriptSegment(text: "Hello.", languageCode: "en"),
            translation: HeptapodTranslatedText(
                sourceText: "Hello.", translatedText: "Merhaba.", sourceLanguageCode: "en", targetLanguageCode: "tr"
            ),
            speech: HeptapodSynthesizedSpeech(pcm16: Data([1, 0]), sampleRate: 16_000, languageCode: "tr")
        )
    }
}

private struct TraceTimingRow: Decodable {
    let event: String
    let index: Int?
    let outputID: Int?
    let elapsedSeconds: Double
    let transcriptText: String?
    let firstAudioLatencySeconds: Double?
    let outputLatencySeconds: Double?
    let playbackDurationSeconds: Double?
}

private struct TraceTimingPlaybackSink: HeptapodSpeechPlaybackSink {
    func play(_ speech: HeptapodSynthesizedSpeech) async throws {
        try await Task.sleep(for: .milliseconds(50))
    }
}

private struct TraceTimingGate: Sendable {
    private let pair = AsyncStream<Void>.makeStream()

    func open() { pair.continuation.finish() }

    func wait() async throws {
        for await _ in pair.stream {}
        try Task.checkCancellation()
    }
}

private struct TraceTimingRecognizer: HeptapodSpeechRecognizer {
    let descriptor = HeptapodModelDescriptor.qwenASRCompact
    func prepare() async throws {}
    func reset() async {}
    func finish(languageHint: String?) async throws -> HeptapodTranscriptSegment? { nil }
    func transcribe(_ chunk: HeptapodAudioChunk, languageHint: String?) async throws -> HeptapodTranscriptSegment? {
        HeptapodTranscriptSegment(text: String(decoding: chunk.pcm16, as: UTF8.self), languageCode: languageHint)
    }
}

private actor TraceTimingTranslator: HeptapodTextTranslator {
    nonisolated let descriptor = HeptapodModelDescriptor.madladTranslator
    let secondStarted: TraceTimingGate
    private var calls = 0

    init(secondStarted: TraceTimingGate) { self.secondStarted = secondStarted }
    func prepare() async throws {}
    func translate(_ text: String, sourceLanguageCode: String?, targetLanguageCode: String) async throws -> HeptapodTranslatedText {
        calls += 1
        if calls == 2 { secondStarted.open() }
        return HeptapodTranslatedText(
            sourceText: text,
            translatedText: text,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode
        )
    }
}

private actor TraceTimingSynthesizer: HeptapodSpeechSynthesizer {
    nonisolated let descriptor = HeptapodModelDescriptor.kokoroTTS
    let firstStarted: TraceTimingGate
    let releaseFirst: TraceTimingGate
    private var calls = 0

    init(firstStarted: TraceTimingGate, releaseFirst: TraceTimingGate) {
        self.firstStarted = firstStarted
        self.releaseFirst = releaseFirst
    }
    func prepare() async throws {}
    func synthesize(_ text: String, languageCode: String, voiceID: String?) async throws -> HeptapodSynthesizedSpeech {
        calls += 1
        if calls == 1 {
            firstStarted.open()
            try await releaseFirst.wait()
        }
        return HeptapodSynthesizedSpeech(pcm16: Data([1, 0]), sampleRate: 16_000, languageCode: languageCode)
    }
}
