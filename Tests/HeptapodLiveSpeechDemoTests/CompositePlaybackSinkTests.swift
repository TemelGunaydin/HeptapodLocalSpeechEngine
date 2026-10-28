import Foundation
import HeptapodLocalSpeechEngine
import Testing
@testable import HeptapodLiveSpeechDemo

@Suite(.timeLimit(.minutes(1)))
struct CompositePlaybackSinkTests {
    @Test
    func schedulesAheadOnlyAfterArchiveFinishesAndWaitsForSpeakerCompletion() async throws {
        let speaker = CompositeTestSpeaker()
        let archive = CompositeTestArchive()
        let sink = CompositePlaybackSink(sinks: [speaker, archive])
        let notifications = CompositeTestNotifications()
        let task = Task {
            try await sink.play(audio()) { await notifications.scheduled() }
            await notifications.completed()
        }
        defer { task.cancel(); speaker.release.open(); archive.release.open() }

        try await speaker.scheduled.wait()
        try await archive.started.wait()
        #expect(await notifications.count == 0)
        archive.release.open()
        try await notifications.ready.wait()
        #expect(await notifications.count == 1)
        #expect(await notifications.didComplete == false)
        #expect(await archive.bytes == Data([1, 2, 3, 4]))
        #expect(await speaker.bytes == Data([1, 2, 3, 4]))
        speaker.release.open()
        try await task.value
        #expect(await notifications.didComplete)
    }

    @Test
    func cancellationReachesSpeakerInsideComposite() async {
        let speaker = CompositeTestSpeaker()
        let sink = CompositePlaybackSink(sinks: [speaker, CompositeTestArchive()])
        await sink.cancelPlayback()
        #expect(await speaker.wasCancelled)
    }

    private func audio() -> AsyncThrowingStream<HeptapodSynthesizedSpeech, Error> {
        let pair = AsyncThrowingStream<HeptapodSynthesizedSpeech, Error>.makeStream()
        for bytes: [UInt8] in [[1, 2], [3, 4]] {
            pair.continuation.yield(HeptapodSynthesizedSpeech(
                pcm16: Data(bytes), sampleRate: 24_000, languageCode: "tr"
            ))
        }
        pair.continuation.finish()
        return pair.stream
    }
}

private struct CompositeTestGate: Sendable {
    private let pair = AsyncStream<Void>.makeStream()
    func open() { pair.continuation.finish() }
    func wait() async throws {
        for await _ in pair.stream {}
        try Task.checkCancellation()
    }
}

private actor CompositeTestNotifications {
    nonisolated let ready = CompositeTestGate()
    private(set) var count = 0
    private(set) var didComplete = false
    func scheduled() { count += 1; ready.open() }
    func completed() { didComplete = true }
}

private actor CompositeTestSpeaker: HeptapodContinuousSpeechPlaybackSink, HeptapodCancellableSpeechPlaybackSink {
    nonisolated let scheduled = CompositeTestGate()
    nonisolated let release = CompositeTestGate()
    private(set) var bytes = Data()
    private(set) var wasCancelled = false

    func play(_ speech: HeptapodSynthesizedSpeech) async throws {
        Issue.record("Expected streaming playback")
    }

    func play(_ stream: AsyncThrowingStream<HeptapodSynthesizedSpeech, Error>) async throws {
        Issue.record("Expected scheduling callback")
        try await play(stream, onScheduled: {})
    }

    func play(
        _ stream: AsyncThrowingStream<HeptapodSynthesizedSpeech, Error>,
        onScheduled: @escaping @Sendable () async -> Void
    ) async throws {
        for try await chunk in stream { bytes.append(chunk.pcm16) }
        await onScheduled()
        scheduled.open()
        try await release.wait()
    }

    func cancelPlayback() async { wasCancelled = true; release.open() }
}

private actor CompositeTestArchive: HeptapodSpeechPlaybackSink {
    nonisolated let started = CompositeTestGate()
    nonisolated let release = CompositeTestGate()
    private(set) var bytes = Data()

    func play(_ speech: HeptapodSynthesizedSpeech) async throws {
        started.open()
        try await release.wait()
        bytes = speech.pcm16
    }
}
