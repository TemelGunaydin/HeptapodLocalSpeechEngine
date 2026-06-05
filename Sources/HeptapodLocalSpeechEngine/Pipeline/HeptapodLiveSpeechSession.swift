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

    public init(
        flushOnSilence: Bool = true,
        flushOnStreamEnd: Bool = true,
        flushOnTerminalPunctuation: Bool = false,
        maximumBufferedSegments: Int = 8,
        minimumWordsForPunctuationEndpoint: Int = 8
    ) {
        self.flushOnSilence = flushOnSilence
        self.flushOnStreamEnd = flushOnStreamEnd
        self.flushOnTerminalPunctuation = flushOnTerminalPunctuation
        self.maximumBufferedSegments = maximumBufferedSegments
        self.minimumWordsForPunctuationEndpoint = minimumWordsForPunctuationEndpoint
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
            let task = Task {
                do {
                    var index = 0
                    var pending = PendingSentence()

                    for try await chunk in chunks {
                        index += 1
                        continuation.yield(.segmentStarted(index: index))

                        guard let transcript = try await pipeline.transcribeSpeech(
                            chunk,
                            sourceLanguageCode: sourceLanguageCode
                        ) else {
                            if endpointing.flushOnSilence, pending.hasText {
                                try await flushPending(
                                    &pending,
                                    at: index,
                                    pipeline: pipeline,
                                    sourceLanguageCode: sourceLanguageCode,
                                    targetLanguageCode: targetLanguageCode,
                                    voiceID: voiceID,
                                    playbackQueue: playbackQueue,
                                    continuation: continuation
                                )
                            } else {
                                continuation.yield(.silenceSkipped(index: index))
                            }
                            continue
                        }

                        pending.append(transcript)

                        if shouldFlush(pending, endpointing: endpointing) {
                            try await flushPending(
                                &pending,
                                at: index,
                                pipeline: pipeline,
                                sourceLanguageCode: sourceLanguageCode,
                                targetLanguageCode: targetLanguageCode,
                                voiceID: voiceID,
                                playbackQueue: playbackQueue,
                                continuation: continuation
                            )
                        }
                    }

                    if endpointing.flushOnStreamEnd, pending.hasText {
                        try await flushPending(
                            &pending,
                            at: index,
                            pipeline: pipeline,
                            sourceLanguageCode: sourceLanguageCode,
                            targetLanguageCode: targetLanguageCode,
                            voiceID: voiceID,
                            playbackQueue: playbackQueue,
                            continuation: continuation
                        )
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
    pipeline: HeptapodSpeechToSpeechPipeline,
    sourceLanguageCode: String?,
    targetLanguageCode: String,
    voiceID: String?,
    playbackQueue: LivePlaybackQueue,
    continuation: AsyncThrowingStream<HeptapodLiveSpeechEvent, Error>.Continuation
) async throws {
    let transcript = pending.drainTranscript(fallbackLanguageCode: sourceLanguageCode)
    let result = try await pipeline.translateAndSynthesize(
        transcript,
        sourceLanguageCode: sourceLanguageCode,
        targetLanguageCode: targetLanguageCode,
        voiceID: voiceID
    )

    continuation.yield(.result(index: index, result))
    await playbackQueue.enqueue(index: index, speech: result.speech)
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
