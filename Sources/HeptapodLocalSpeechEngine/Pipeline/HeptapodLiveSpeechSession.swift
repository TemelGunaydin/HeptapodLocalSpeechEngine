import Foundation

public protocol HeptapodAudioChunkSource: Sendable {
    func chunks() -> AsyncThrowingStream<HeptapodAudioChunk, Error>
}

public protocol HeptapodSpeechPlaybackSink: Sendable {
    func play(_ speech: HeptapodSynthesizedSpeech) async throws
}

public enum HeptapodLiveSpeechEvent: Sendable {
    case segmentStarted(index: Int)
    case silenceSkipped(index: Int)
    case result(index: Int, HeptapodSpeechToSpeechResult)
    case playbackCompleted(index: Int)
}

public struct HeptapodSentenceEndpointingConfiguration: Sendable {
    public let flushOnSilence: Bool
    public let flushOnStreamEnd: Bool
    public let flushOnTerminalPunctuation: Bool
    public let maximumBufferedSegments: Int
    public let minimumWordsForPunctuationEndpoint: Int
    public let asrStabilization: HeptapodASRStabilizationConfiguration

    public init(
        flushOnSilence: Bool = true,
        flushOnStreamEnd: Bool = true,
        flushOnTerminalPunctuation: Bool = false,
        maximumBufferedSegments: Int = 8,
        minimumWordsForPunctuationEndpoint: Int = 8,
        asrStabilization: HeptapodASRStabilizationConfiguration = .disabled
    ) {
        self.flushOnSilence = flushOnSilence
        self.flushOnStreamEnd = flushOnStreamEnd
        self.flushOnTerminalPunctuation = flushOnTerminalPunctuation
        self.maximumBufferedSegments = maximumBufferedSegments
        self.minimumWordsForPunctuationEndpoint = minimumWordsForPunctuationEndpoint
        self.asrStabilization = asrStabilization
    }
}

public struct HeptapodASRStabilizationConfiguration: Sendable, Equatable {
    public let isEnabled: Bool
    public let maximumWindowChunks: Int
    public let minimumStableWords: Int

    public static let disabled = HeptapodASRStabilizationConfiguration(isEnabled: false)
    public static let lowLatency = HeptapodASRStabilizationConfiguration(
        isEnabled: true,
        maximumWindowChunks: 3,
        minimumStableWords: 2
    )

    public init(
        isEnabled: Bool = true,
        maximumWindowChunks: Int = 3,
        minimumStableWords: Int = 2
    ) {
        self.isEnabled = isEnabled
        self.maximumWindowChunks = max(1, maximumWindowChunks)
        self.minimumStableWords = max(1, minimumStableWords)
    }
}

public actor HeptapodLiveSpeechSession {
    private let pipeline: HeptapodSpeechToSpeechPipeline
    private let sourceLanguageCode: String?
    private let targetLanguageCode: String
    private let voiceID: String?
    private let playbackSink: (any HeptapodSpeechPlaybackSink)?

    public init(
        pipeline: HeptapodSpeechToSpeechPipeline,
        sourceLanguageCode: String?,
        targetLanguageCode: String,
        voiceID: String? = nil,
        playbackSink: (any HeptapodSpeechPlaybackSink)? = nil
    ) {
        self.pipeline = pipeline
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
        self.voiceID = voiceID
        self.playbackSink = playbackSink
    }

    public func run<Chunks: AsyncSequence & Sendable>(
        chunks: Chunks
    ) -> AsyncThrowingStream<HeptapodLiveSpeechEvent, Error> where Chunks.Element == HeptapodAudioChunk {
        let pipeline = pipeline
        let sourceLanguageCode = sourceLanguageCode
        let targetLanguageCode = targetLanguageCode
        let voiceID = voiceID
        let playbackSink = playbackSink

        return AsyncThrowingStream { continuation in
            let playbackQueue = LivePlaybackQueue(sink: playbackSink, continuation: continuation)
            let task = Task {
                do {
                    var index = 0
                    for try await chunk in chunks {
                        index += 1
                        continuation.yield(.segmentStarted(index: index))

                        guard let result = try await pipeline.processDetailed(
                            chunk,
                            sourceLanguageCode: sourceLanguageCode,
                            targetLanguageCode: targetLanguageCode,
                            voiceID: voiceID
                        ) else {
                            continuation.yield(.silenceSkipped(index: index))
                            continue
                        }

                        continuation.yield(.result(index: index, result))
                        await playbackQueue.enqueue(index: index, speech: result.speech)
                    }

                    try await playbackQueue.drain()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
                Task {
                    await playbackQueue.cancel()
                }
            }
        }
    }

    public func runSentenceBuffered<Chunks: AsyncSequence & Sendable>(
        chunks: Chunks,
        endpointing: HeptapodSentenceEndpointingConfiguration = HeptapodSentenceEndpointingConfiguration()
    ) -> AsyncThrowingStream<HeptapodLiveSpeechEvent, Error> where Chunks.Element == HeptapodAudioChunk {
        let pipeline = pipeline
        let sourceLanguageCode = sourceLanguageCode
        let targetLanguageCode = targetLanguageCode
        let voiceID = voiceID
        let playbackSink = playbackSink

        return AsyncThrowingStream { continuation in
            let playbackQueue = LivePlaybackQueue(sink: playbackSink, continuation: continuation)
            let synthesisQueue = LiveSynthesisQueue(
                pipeline: pipeline,
                sourceLanguageCode: sourceLanguageCode,
                targetLanguageCode: targetLanguageCode,
                voiceID: voiceID,
                playbackQueue: playbackQueue,
                continuation: continuation
            )
            let task = Task {
                do {
                    var index = 0
                    var pending = PendingSentence()
                    var asrStabilizer = SlidingASRStabilizer(configuration: endpointing.asrStabilization)

                    for try await chunk in chunks {
                        index += 1
                        continuation.yield(.segmentStarted(index: index))

                        let transcript: HeptapodTranscriptSegment?
                        let isSpeechBuffered: Bool
                        if endpointing.asrStabilization.isEnabled {
                            guard try await pipeline.containsSpeech(chunk) else {
                                if let finalTranscript = asrStabilizer.flushLatest(fallbackLanguageCode: sourceLanguageCode) {
                                    pending.append(finalTranscript)
                                }
                                if endpointing.flushOnSilence, pending.hasText {
                                    await flushPending(
                                        &pending,
                                        at: index,
                                        synthesisQueue: synthesisQueue,
                                        sourceLanguageCode: sourceLanguageCode
                                    )
                                } else {
                                    continuation.yield(.silenceSkipped(index: index))
                                }
                                asrStabilizer.reset()
                                continue
                            }

                            let windowChunk = asrStabilizer.append(chunk)
                            let hypothesis = try await pipeline.recognizeSpeech(
                                windowChunk,
                                sourceLanguageCode: sourceLanguageCode
                            )
                            transcript = hypothesis.flatMap { asrStabilizer.commitStablePrefix(from: $0) }
                            isSpeechBuffered = hypothesis != nil
                        } else {
                            transcript = try await pipeline.transcribeSpeech(
                                chunk,
                                sourceLanguageCode: sourceLanguageCode
                            )
                            isSpeechBuffered = false
                        }

                        guard let transcript else {
                            if endpointing.flushOnSilence, pending.hasText {
                                await flushPending(
                                    &pending,
                                    at: index,
                                    synthesisQueue: synthesisQueue,
                                    sourceLanguageCode: sourceLanguageCode
                                )
                            } else if isSpeechBuffered {
                                continue
                            } else {
                                continuation.yield(.silenceSkipped(index: index))
                            }
                            continue
                        }

                        pending.append(transcript)

                        if shouldFlush(pending, endpointing: endpointing) {
                            await flushPending(
                                &pending,
                                at: index,
                                synthesisQueue: synthesisQueue,
                                sourceLanguageCode: sourceLanguageCode
                            )
                        }
                    }

                    if let finalTranscript = asrStabilizer.flushLatest(fallbackLanguageCode: sourceLanguageCode) {
                        pending.append(finalTranscript)
                    }
                    if endpointing.flushOnStreamEnd, pending.hasText {
                        await flushPending(
                            &pending,
                            at: index,
                            synthesisQueue: synthesisQueue,
                            sourceLanguageCode: sourceLanguageCode
                        )
                    }

                    try await synthesisQueue.drain()
                    try await playbackQueue.drain()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
                Task {
                    await synthesisQueue.cancel()
                    await playbackQueue.cancel()
                }
            }
        }
    }
}

private struct PendingSentence {
    private var parts: [String] = []
    private var languageCode: String?
    private(set) var segmentCount = 0

    var hasText: Bool {
        text.isEmpty == false
    }

    var text: String {
        parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var wordCount: Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    var endsWithTerminalPunctuation: Bool {
        guard let last = text.last else {
            return false
        }
        let terminalPunctuation: Set<Character> = [".", "?", "!", "。", "؟", "！"]
        return terminalPunctuation.contains(last)
    }

    mutating func append(_ transcript: HeptapodTranscriptSegment) {
        let trimmed = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return
        }
        parts.append(trimmed)
        languageCode = transcript.languageCode ?? languageCode
        segmentCount += 1
    }

    mutating func drainTranscript(fallbackLanguageCode: String?) -> HeptapodTranscriptSegment {
        let segment = HeptapodTranscriptSegment(
            text: text,
            languageCode: languageCode ?? fallbackLanguageCode,
            isFinal: true
        )
        parts.removeAll()
        languageCode = nil
        segmentCount = 0
        return segment
    }
}

private func shouldFlush(
    _ pending: PendingSentence,
    endpointing: HeptapodSentenceEndpointingConfiguration
) -> Bool {
    guard pending.hasText else {
        return false
    }
    if pending.segmentCount >= endpointing.maximumBufferedSegments {
        return true
    }
    if endpointing.flushOnTerminalPunctuation,
       pending.wordCount >= endpointing.minimumWordsForPunctuationEndpoint,
       pending.endsWithTerminalPunctuation {
        return true
    }
    return false
}

private func flushPending(
    _ pending: inout PendingSentence,
    at index: Int,
    synthesisQueue: LiveSynthesisQueue,
    sourceLanguageCode: String?
) async {
    let transcript = pending.drainTranscript(fallbackLanguageCode: sourceLanguageCode)
    await synthesisQueue.enqueue(index: index, transcript: transcript)
}

private struct SlidingASRStabilizer {
    private let configuration: HeptapodASRStabilizationConfiguration
    private var chunks: [HeptapodAudioChunk] = []
    private var lastHypothesis: HeptapodTranscriptSegment?
    private var committedWords: [String] = []

    init(configuration: HeptapodASRStabilizationConfiguration) {
        self.configuration = configuration
    }

    mutating func append(_ chunk: HeptapodAudioChunk) -> HeptapodAudioChunk {
        chunks.append(chunk)
        if chunks.count > configuration.maximumWindowChunks {
            chunks.removeFirst(chunks.count - configuration.maximumWindowChunks)
        }
        return Self.combine(chunks)
    }

    mutating func commitStablePrefix(from hypothesis: HeptapodTranscriptSegment) -> HeptapodTranscriptSegment? {
        defer {
            lastHypothesis = hypothesis
        }

        guard let lastHypothesis else {
            return nil
        }

        let stableWords = Self.commonPrefixWords(
            Self.words(in: lastHypothesis.text),
            Self.words(in: hypothesis.text)
        )
        guard stableWords.count >= configuration.minimumStableWords else {
            return nil
        }

        return commitDelta(
            stableWords,
            languageCode: hypothesis.languageCode ?? lastHypothesis.languageCode
        )
    }

    mutating func flushLatest(fallbackLanguageCode: String?) -> HeptapodTranscriptSegment? {
        defer {
            reset()
        }

        guard let lastHypothesis else {
            return nil
        }
        return commitDelta(
            Self.words(in: lastHypothesis.text),
            languageCode: lastHypothesis.languageCode ?? fallbackLanguageCode
        )
    }

    mutating func reset() {
        chunks.removeAll()
        lastHypothesis = nil
        committedWords.removeAll()
    }

    private mutating func commitDelta(_ candidateWords: [String], languageCode: String?) -> HeptapodTranscriptSegment? {
        guard candidateWords.count > committedWords.count else {
            return nil
        }

        let committedPrefix = Array(candidateWords.prefix(committedWords.count))
        if committedPrefix != committedWords {
            committedWords.removeAll()
        }

        let deltaWords = Array(candidateWords.dropFirst(committedWords.count))
        guard deltaWords.isEmpty == false else {
            return nil
        }

        committedWords = candidateWords
        return HeptapodTranscriptSegment(
            text: deltaWords.joined(separator: " "),
            languageCode: languageCode,
            isFinal: true
        )
    }

    private static func words(in text: String) -> [String] {
        text.split { $0.isWhitespace || $0.isNewline }.map(String.init)
    }

    private static func commonPrefixWords(_ lhs: [String], _ rhs: [String]) -> [String] {
        var result: [String] = []
        for (left, right) in zip(lhs, rhs) {
            guard left == right else {
                break
            }
            result.append(left)
        }
        return result
    }

    private static func combine(_ chunks: [HeptapodAudioChunk]) -> HeptapodAudioChunk {
        guard let first = chunks.first else {
            return HeptapodAudioChunk(pcm16: Data(), sampleRate: 16_000)
        }
        var data = Data()
        for chunk in chunks {
            data.append(chunk.pcm16)
        }
        return HeptapodAudioChunk(pcm16: data, sampleRate: first.sampleRate)
    }
}

private actor LiveSynthesisQueue {
    private let pipeline: HeptapodSpeechToSpeechPipeline
    private let sourceLanguageCode: String?
    private let targetLanguageCode: String
    private let voiceID: String?
    private let playbackQueue: LivePlaybackQueue
    private let continuation: AsyncThrowingStream<HeptapodLiveSpeechEvent, Error>.Continuation
    private var tail: Task<Void, Error>?

    init(
        pipeline: HeptapodSpeechToSpeechPipeline,
        sourceLanguageCode: String?,
        targetLanguageCode: String,
        voiceID: String?,
        playbackQueue: LivePlaybackQueue,
        continuation: AsyncThrowingStream<HeptapodLiveSpeechEvent, Error>.Continuation
    ) {
        self.pipeline = pipeline
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
        self.voiceID = voiceID
        self.playbackQueue = playbackQueue
        self.continuation = continuation
    }

    func enqueue(index: Int, transcript: HeptapodTranscriptSegment) {
        let previous = tail
        tail = Task {
            try await previous?.value
            try Task.checkCancellation()
            let result = try await pipeline.translateAndSynthesize(
                transcript,
                sourceLanguageCode: sourceLanguageCode,
                targetLanguageCode: targetLanguageCode,
                voiceID: voiceID
            )
            continuation.yield(.result(index: index, result))
            await playbackQueue.enqueue(index: index, speech: result.speech)
        }
    }

    func drain() async throws {
        try await tail?.value
    }

    func cancel() {
        tail?.cancel()
    }
}

private actor LivePlaybackQueue {
    private let sink: (any HeptapodSpeechPlaybackSink)?
    private let continuation: AsyncThrowingStream<HeptapodLiveSpeechEvent, Error>.Continuation
    private var tail: Task<Void, Error>?

    init(
        sink: (any HeptapodSpeechPlaybackSink)?,
        continuation: AsyncThrowingStream<HeptapodLiveSpeechEvent, Error>.Continuation
    ) {
        self.sink = sink
        self.continuation = continuation
    }

    func enqueue(index: Int, speech: HeptapodSynthesizedSpeech) {
        guard let sink else {
            return
        }

        let previous = tail
        tail = Task {
            try await previous?.value
            try Task.checkCancellation()
            try await sink.play(speech)
            continuation.yield(.playbackCompleted(index: index))
        }
    }

    func drain() async throws {
        try await tail?.value
    }

    func cancel() {
        tail?.cancel()
    }
}

public struct HeptapodArrayAudioChunkSource: HeptapodAudioChunkSource {
    public let audioChunks: [HeptapodAudioChunk]
    public let interval: Duration?

    public init(audioChunks: [HeptapodAudioChunk], interval: Duration? = nil) {
        self.audioChunks = audioChunks
        self.interval = interval
    }

    public func chunks() -> AsyncThrowingStream<HeptapodAudioChunk, Error> {
        let audioChunks = audioChunks
        let interval = interval

        return AsyncThrowingStream { continuation in
            let task = Task {
                for chunk in audioChunks {
                    if let interval {
                        try Task.checkCancellation()
                        try await Task.sleep(for: interval)
                    }
                    continuation.yield(chunk)
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
