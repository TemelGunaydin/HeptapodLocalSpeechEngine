import Foundation

public protocol HeptapodAudioChunkSource: Sendable {
    func chunks() -> AsyncThrowingStream<HeptapodAudioChunk, Error>
}

public protocol HeptapodSpeechPlaybackSink: Sendable {
    func play(_ speech: HeptapodSynthesizedSpeech) async throws
}

public enum HeptapodLiveSpeechEvent: Sendable {
    case segmentStarted(index: Int)
    case audioLevel(index: Int, HeptapodAudioLevel)
    case silenceSkipped(index: Int)
    case transcript(index: Int, HeptapodTranscriptSegment)
    case translation(index: Int, HeptapodLiveTranslationResult)
    case result(index: Int, HeptapodSpeechToSpeechResult)
    case playbackCompleted(index: Int)
}

public enum HeptapodLiveOutputMode: Sendable, Equatable {
    case speech
    case textOnly
}

public struct HeptapodAudioLevel: Sendable, Equatable {
    public let rms: Double
    public let peak: Double

    public init(rms: Double, peak: Double) {
        self.rms = rms
        self.peak = peak
    }

    public static func measured(from chunk: HeptapodAudioChunk) -> HeptapodAudioLevel {
        var sumSquares = 0.0
        var peak = 0.0
        var sampleCount = 0
        let bytes = chunk.pcm16

        bytes.withUnsafeBytes { rawBuffer in
            let byteBuffer = rawBuffer.bindMemory(to: UInt8.self)
            var byteIndex = 0
            while byteIndex + 1 < byteBuffer.count {
                let low = UInt16(byteBuffer[byteIndex])
                let high = UInt16(byteBuffer[byteIndex + 1]) << 8
                let sample = Int16(bitPattern: high | low)
                let value = Double(sample) / 32768.0
                sumSquares += value * value
                peak = max(peak, abs(value))
                sampleCount += 1
                byteIndex += 2
            }
        }

        guard sampleCount > 0 else {
            return HeptapodAudioLevel(rms: 0, peak: 0)
        }

        return HeptapodAudioLevel(
            rms: sqrt(sumSquares / Double(sampleCount)),
            peak: peak
        )
    }
}

public struct HeptapodLiveTranslationResult: Sendable {
    public let transcript: HeptapodTranscriptSegment
    public let translation: HeptapodTranslatedText

    public init(transcript: HeptapodTranscriptSegment, translation: HeptapodTranslatedText) {
        self.transcript = transcript
        self.translation = translation
    }
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
    private let outputMode: HeptapodLiveOutputMode

    public init(
        pipeline: HeptapodSpeechToSpeechPipeline,
        sourceLanguageCode: String?,
        targetLanguageCode: String,
        voiceID: String? = nil,
        playbackSink: (any HeptapodSpeechPlaybackSink)? = nil,
        outputMode: HeptapodLiveOutputMode = .speech
    ) {
        self.pipeline = pipeline
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
        self.voiceID = voiceID
        self.playbackSink = playbackSink
        self.outputMode = outputMode
    }

    public func run<Chunks: AsyncSequence & Sendable>(
        chunks: Chunks
    ) -> AsyncThrowingStream<HeptapodLiveSpeechEvent, Error> where Chunks.Element == HeptapodAudioChunk {
        let pipeline = pipeline
        let sourceLanguageCode = sourceLanguageCode
        let targetLanguageCode = targetLanguageCode
        let voiceID = voiceID
        let playbackSink = playbackSink
        let outputMode = outputMode

        return AsyncThrowingStream { continuation in
            let playbackQueue = LivePlaybackQueue(sink: playbackSink, continuation: continuation)
            let task = Task {
                do {
                    var index = 0
                    for try await chunk in chunks {
                        index += 1
                        continuation.yield(.segmentStarted(index: index))
                        continuation.yield(.audioLevel(index: index, .measured(from: chunk)))

                        guard let transcript = try await pipeline.transcribeSpeech(
                            chunk,
                            sourceLanguageCode: sourceLanguageCode
                        ) else {
                            continuation.yield(.silenceSkipped(index: index))
                            continue
                        }

                        switch outputMode {
                        case .speech:
                            let result = try await pipeline.translateAndSynthesize(
                                transcript,
                                sourceLanguageCode: sourceLanguageCode,
                                targetLanguageCode: targetLanguageCode,
                                voiceID: voiceID
                            )
                            continuation.yield(.result(index: index, result))
                            await playbackQueue.enqueue(index: index, speech: result.speech)
                        case .textOnly:
                            continuation.yield(.transcript(index: index, transcript))
                            let translation = try await pipeline.translateTranscript(
                                transcript,
                                sourceLanguageCode: sourceLanguageCode,
                                targetLanguageCode: targetLanguageCode
                            )
                            continuation.yield(.translation(
                                index: index,
                                HeptapodLiveTranslationResult(transcript: transcript, translation: translation)
                            ))
                        }
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
        let outputMode = outputMode

        return AsyncThrowingStream { continuation in
            let playbackQueue = LivePlaybackQueue(sink: playbackSink, continuation: continuation)
            let synthesisQueue = LiveSynthesisQueue(
                pipeline: pipeline,
                sourceLanguageCode: sourceLanguageCode,
                targetLanguageCode: targetLanguageCode,
                voiceID: voiceID,
                playbackQueue: playbackQueue,
                continuation: continuation,
                outputMode: outputMode
            )
            let task = Task {
                do {
                    var index = 0
                    var pending = PendingSentence()
                    var asrStabilizer = SlidingASRStabilizer(configuration: endpointing.asrStabilization)

                    for try await chunk in chunks {
                        index += 1
                        continuation.yield(.segmentStarted(index: index))
                        continuation.yield(.audioLevel(index: index, .measured(from: chunk)))

                        let transcript: HeptapodTranscriptSegment?
                        let isSpeechBuffered: Bool
                        if endpointing.asrStabilization.isEnabled {
                            guard try await pipeline.containsSpeech(chunk) else {
                                if let finalTranscript = asrStabilizer.flushLatest(fallbackLanguageCode: sourceLanguageCode) {
                                    if outputMode == .textOnly {
                                        continuation.yield(.transcript(index: index, finalTranscript))
                                    }
                                    pending.append(finalTranscript)
                                }
                                if endpointing.flushOnSilence, pending.hasText {
                                    let didFlush = await flushPending(
                                        &pending,
                                        at: index,
                                        synthesisQueue: synthesisQueue,
                                        sourceLanguageCode: sourceLanguageCode
                                    )
                                    if didFlush == false {
                                        continuation.yield(.silenceSkipped(index: index))
                                    }
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
                                let didFlush = await flushPending(
                                    &pending,
                                    at: index,
                                    synthesisQueue: synthesisQueue,
                                    sourceLanguageCode: sourceLanguageCode
                                )
                                if didFlush == false {
                                    continuation.yield(.silenceSkipped(index: index))
                                }
                            } else if isSpeechBuffered {
                                continue
                            } else {
                                continuation.yield(.silenceSkipped(index: index))
                            }
                            continue
                        }

                        if outputMode == .textOnly {
                            continuation.yield(.transcript(index: index, transcript))
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
                        if outputMode == .textOnly {
                            continuation.yield(.transcript(index: index, finalTranscript))
                        }
                        pending.append(finalTranscript)
                    }
                    if endpointing.flushOnStreamEnd, pending.hasText {
                        await flushPending(
                            &pending,
                            at: index,
                            synthesisQueue: synthesisQueue,
                            sourceLanguageCode: sourceLanguageCode,
                            retainsIncompleteTail: false
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

    var translationText: String {
        TranscriptTranslationNormalizer.normalized(text)
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

    mutating func drainTranscript(
        fallbackLanguageCode: String?,
        retainsIncompleteTail: Bool = true
    ) -> HeptapodTranscriptSegment? {
        let split = retainsIncompleteTail
            ? TranscriptTranslationNormalizer.readyTextAndRemainder(text)
            : TranscriptTranslationNormalizer.readyTextOnly(text)
        let retainedLanguageCode = languageCode

        parts.removeAll()
        if split.remainderText.isEmpty == false {
            parts.append(split.remainderText)
            languageCode = retainedLanguageCode
            segmentCount = 0
        } else {
            languageCode = nil
            segmentCount = 0
        }

        guard split.readyText.isEmpty == false else {
            return nil
        }

        let segment = HeptapodTranscriptSegment(
            text: split.readyText,
            languageCode: retainedLanguageCode ?? fallbackLanguageCode,
            isFinal: true
        )
        return segment
    }
}

private struct TranscriptTranslationNormalizer {
    struct Split {
        let readyText: String
        let remainderText: String
    }

    private struct Fragment {
        let text: String
        let punctuation: Character?

        var wordCount: Int {
            words(in: text).count
        }
    }

    static func normalized(_ text: String) -> String {
        let fragments = collapseDuplicatePrefixes(fragments(in: text))
        return normalized(fragments)
    }

    static func readyTextAndRemainder(_ text: String) -> Split {
        let fragments = collapseDuplicatePrefixes(fragments(in: text))
        guard fragments.isEmpty == false else {
            return Split(
                readyText: "",
                remainderText: text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard hasIncompleteTail(fragments) else {
            return Split(readyText: normalized(fragments), remainderText: "")
        }

        let tailStartIndex = incompleteTailStartIndex(in: fragments)
        let readyFragments = Array(fragments[..<tailStartIndex])
        let remainderFragments = Array(fragments[tailStartIndex...])
        return Split(
            readyText: normalized(readyFragments),
            remainderText: normalized(remainderFragments)
        )
    }

    static func readyTextOnly(_ text: String) -> Split {
        Split(readyText: normalized(text), remainderText: "")
    }

    private static func normalized(_ fragments: [Fragment]) -> String {
        guard fragments.isEmpty == false else {
            return ""
        }
        var output: [String] = []
        var carry = ""

        for index in fragments.indices {
            let fragment = fragments[index]
            let next = fragments.index(after: index) < fragments.endIndex
                ? fragments[fragments.index(after: index)]
                : nil
            let fragmentText = carry.isEmpty
                ? fragment.text
                : normalizedContinuationText(fragment.text, after: carry)
            carry = carry.isEmpty ? fragmentText : "\(carry) \(fragmentText)"

            guard shouldJoin(fragment, with: next) else {
                output.append(withTerminalPunctuation(carry, punctuation: fragment.punctuation))
                carry = ""
                continue
            }
        }

        if carry.isEmpty == false {
            output.append(carry)
        }

        return output
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasIncompleteTail(_ fragments: [Fragment]) -> Bool {
        guard let last = fragments.last,
              let lastWord = lastWord(in: last.text) else {
            return false
        }
        return trailingContinuationWords.contains(lastWord)
            || endsWithContinuationPhrase(last.text)
            || objectExpectingWords.contains(lastWord)
    }

    private static func incompleteTailStartIndex(in fragments: [Fragment]) -> Array<Fragment>.Index {
        var currentIndex = fragments.index(before: fragments.endIndex)
        while currentIndex > fragments.startIndex {
            let previousIndex = fragments.index(before: currentIndex)
            guard shouldRetainIncompleteTail(fragments[previousIndex], with: fragments[currentIndex]) else {
                break
            }
            currentIndex = previousIndex
        }
        return currentIndex
    }

    private static func fragments(in text: String) -> [Fragment] {
        var result: [Fragment] = []
        var current = ""
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if isTerminalPunctuation(character),
               isSentenceBoundary(after: index, in: text) {
                appendFragment(current, punctuation: character, to: &result)
                current.removeAll()
            } else {
                current.append(character)
            }
            index = text.index(after: index)
        }

        appendFragment(current, punctuation: nil, to: &result)
        return result
    }

    private static func appendFragment(
        _ text: String,
        punctuation: Character?,
        to result: inout [Fragment]
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return
        }
        result.append(Fragment(text: trimmed, punctuation: punctuation))
    }

    private static func collapseDuplicatePrefixes(_ fragments: [Fragment]) -> [Fragment] {
        var result: [Fragment] = []
        for fragment in fragments {
            if let last = result.last {
                let lastComparable = comparable(last.text)
                let currentComparable = comparable(fragment.text)
                if currentComparable == lastComparable {
                    continue
                }
                if last.wordCount <= 3,
                   currentComparable.hasPrefix("\(lastComparable) ") {
                    result.removeLast()
                }
            }
            result.append(fragment)
        }
        return result
    }

    private static func shouldJoin(_ fragment: Fragment, with next: Fragment?) -> Bool {
        guard let next else {
            return false
        }
        guard fragment.punctuation == "." || fragment.punctuation == nil else {
            return false
        }
        if let last = lastWord(in: fragment.text),
           trailingContinuationWords.contains(last) {
            return true
        }
        if endsWithContinuationPhrase(fragment.text) {
            return true
        }
        if shouldJoinObjectPhrase(fragment, with: next) {
            return true
        }
        if shouldJoinDuplicateBoundary(fragment, with: next) {
            return true
        }
        if let first = firstWord(in: next.text),
           leadingContinuationWords.contains(first) {
            return true
        }
        return false
    }

    private static func shouldRetainIncompleteTail(_ fragment: Fragment, with next: Fragment) -> Bool {
        guard fragment.punctuation == "." || fragment.punctuation == nil else {
            return false
        }
        if let last = lastWord(in: fragment.text),
           trailingContinuationWords.contains(last) {
            return true
        }
        if endsWithContinuationPhrase(fragment.text) {
            return true
        }
        if shouldJoinObjectPhrase(fragment, with: next) {
            return true
        }
        if let first = firstWord(in: next.text),
           retainedLeadingContinuationWords.contains(first) {
            return true
        }
        return false
    }

    private static func withTerminalPunctuation(_ text: String, punctuation: Character?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let punctuation else {
            return trimmed
        }
        guard trimmed.last.map(isTerminalPunctuation) != true else {
            return trimmed
        }
        return "\(trimmed)\(punctuation)"
    }

    private static func removingDuplicateBoundaryWord(from next: String, after current: String) -> String {
        guard let currentLast = lastWord(in: current),
              let nextFirst = firstWord(in: next),
              currentLast == nextFirst else {
            return next
        }
        return removingFirstWord(from: next)
    }

    private static func normalizedContinuationText(_ next: String, after current: String) -> String {
        let withoutDuplicateBoundary = removingDuplicateBoundaryWord(from: next, after: current)
        if let last = lastWord(in: current),
           trailingContinuationWords.contains(last) {
            return lowercasingFirstWord(in: withoutDuplicateBoundary)
        }
        if endsWithContinuationPhrase(current) {
            return lowercasingFirstWord(in: withoutDuplicateBoundary)
        }
        if let last = lastWord(in: current),
           objectExpectingWords.contains(last) {
            return lowercasingFirstWord(in: withoutDuplicateBoundary)
        }
        guard let first = firstWord(in: withoutDuplicateBoundary),
              leadingContinuationWords.contains(first) else {
            return withoutDuplicateBoundary
        }
        return lowercasingFirstWord(in: withoutDuplicateBoundary)
    }

    private static func lowercasingFirstWord(in text: String) -> String {
        guard let range = firstWordRange(in: text) else {
            return text
        }
        if text[range] == "I" {
            return text
        }
        var result = text
        result.replaceSubrange(range, with: result[range].lowercased())
        return result
    }

    private static func removingFirstWord(from text: String) -> String {
        guard let range = firstWordRange(in: text) else {
            return text
        }
        var result = text
        result.removeSubrange(range)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func words(in text: String) -> [String] {
        text.split { character in
            character.isLetter == false && character.isNumber == false && character != "'"
        }
        .map { $0.lowercased() }
    }

    private static func comparable(_ text: String) -> String {
        words(in: text).joined(separator: " ")
    }

    private static func endsWithContinuationPhrase(_ text: String) -> Bool {
        let wordList = words(in: text)
        return continuationPhrases.contains { phrase in
            wordList.suffix(phrase.count) == phrase[...]
        }
    }

    private static func shouldJoinObjectPhrase(_ fragment: Fragment, with next: Fragment) -> Bool {
        guard let last = lastWord(in: fragment.text),
              objectExpectingWords.contains(last),
              let first = firstWord(in: next.text) else {
            return false
        }
        return objectLeadingWords.contains(first)
    }

    private static func shouldJoinDuplicateBoundary(_ fragment: Fragment, with next: Fragment) -> Bool {
        guard fragment.wordCount >= 2,
              next.wordCount >= 2,
              let last = lastWord(in: fragment.text),
              let first = firstWord(in: next.text) else {
            return false
        }
        return last == first
    }

    private static func firstWord(in text: String) -> String? {
        words(in: text).first
    }

    private static func lastWord(in text: String) -> String? {
        words(in: text).last
    }

    private static func firstWordRange(in text: String) -> Range<String.Index>? {
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber || character == "'" {
                start = index
                break
            }
            index = text.index(after: index)
        }
        guard let start else {
            return nil
        }

        var end = start
        while end < text.endIndex {
            let character = text[end]
            guard character.isLetter || character.isNumber || character == "'" else {
                break
            }
            end = text.index(after: end)
        }
        return start..<end
    }

    private static func isTerminalPunctuation(_ character: Character) -> Bool {
        character == "." || character == "?" || character == "!"
    }

    private static func isSentenceBoundary(after index: String.Index, in text: String) -> Bool {
        let nextIndex = text.index(after: index)
        guard nextIndex < text.endIndex else {
            return true
        }
        return text[nextIndex].isWhitespace
    }

    private static let trailingContinuationWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "but", "for", "from", "if",
        "in", "is", "it", "just", "keep", "my", "of", "on", "or", "that",
        "the", "this", "through", "to", "when", "with", "without", "your"
    ]

    private static let leadingContinuationWords: Set<String> = [
        "about", "and", "are", "as", "at", "for", "from", "if", "in", "is",
        "it", "of", "on", "or", "that", "the", "to", "with", "without"
    ]

    private static let retainedLeadingContinuationWords: Set<String> = [
        "about", "and", "are", "as", "at", "for", "from", "if", "in", "is",
        "it", "of", "on", "or", "that", "the", "to", "with", "without"
    ]

    private static let continuationPhrases: [[String]] = [
        ["my", "first"],
        ["a", "peaceful"],
        ["ask", "you"],
        ["i", "feel", "like"],
        ["feel", "like"],
        ["where", "we"]
    ]

    private static let objectExpectingWords: Set<String> = [
        "hold"
    ]

    private static let objectLeadingWords: Set<String> = [
        "a", "an", "my", "the", "this", "your"
    ]
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

@discardableResult
private func flushPending(
    _ pending: inout PendingSentence,
    at index: Int,
    synthesisQueue: LiveSynthesisQueue,
    sourceLanguageCode: String?,
    retainsIncompleteTail: Bool = true
) async -> Bool {
    guard let transcript = pending.drainTranscript(
        fallbackLanguageCode: sourceLanguageCode,
        retainsIncompleteTail: retainsIncompleteTail
    ) else {
        return false
    }
    await synthesisQueue.enqueue(index: index, transcript: transcript)
    return true
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
    private let outputMode: HeptapodLiveOutputMode
    private var tail: Task<Void, Error>?

    init(
        pipeline: HeptapodSpeechToSpeechPipeline,
        sourceLanguageCode: String?,
        targetLanguageCode: String,
        voiceID: String?,
        playbackQueue: LivePlaybackQueue,
        continuation: AsyncThrowingStream<HeptapodLiveSpeechEvent, Error>.Continuation,
        outputMode: HeptapodLiveOutputMode
    ) {
        self.pipeline = pipeline
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
        self.voiceID = voiceID
        self.playbackQueue = playbackQueue
        self.continuation = continuation
        self.outputMode = outputMode
    }

    func enqueue(index: Int, transcript: HeptapodTranscriptSegment) {
        let previous = tail
        tail = Task {
            try await previous?.value
            try Task.checkCancellation()
            switch outputMode {
            case .speech:
                let result = try await pipeline.translateAndSynthesize(
                    transcript,
                    sourceLanguageCode: sourceLanguageCode,
                    targetLanguageCode: targetLanguageCode,
                    voiceID: voiceID
                )
                continuation.yield(.result(index: index, result))
                await playbackQueue.enqueue(index: index, speech: result.speech)
            case .textOnly:
                let translation = try await pipeline.translateTranscript(
                    transcript,
                    sourceLanguageCode: sourceLanguageCode,
                    targetLanguageCode: targetLanguageCode
                )
                continuation.yield(.translation(
                    index: index,
                    HeptapodLiveTranslationResult(transcript: transcript, translation: translation)
                ))
            }
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
