import Foundation
import HeptapodSpeechSwiftAdapters
import Testing
@testable import HeptapodLocalSpeechEngine

private struct PocketWorkerFixture {
    let directory: URL
    let script: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("heptapod-pocket-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        script = directory.appendingPathComponent("worker.py")
        try #"""
        import base64, json, sys, time
        def emit(value):
            print(json.dumps(value), flush=True)
        emit({"ready": True, "sample_rate": 24000})
        for line in sys.stdin:
            r = json.loads(line)
            text = r['text']
            if text == 'wrong-id':
                emit({"id": "wrong", "event": "done"})
                continue
            if text == 'bad-pcm':
                emit({"id": r['id'], "event": "audio", "sample_rate": 24000, "pcm16": "AA=="})
                continue
            if text == 'crash':
                print('fixture worker failed', file=sys.stderr, flush=True)
                sys.exit(2)
            if text == 'timeout':
                time.sleep(60)
            pcm = b'\x01\x00' if r['voice_id'] == 'female_2' else b'\x02\x00'
            for _ in range(2):
                emit({"id": r['id'], "event": "audio", "sample_rate": 24000,
                      "pcm16": base64.b64encode(pcm).decode()})
                if text == 'stall':
                    time.sleep(60)
            emit({"id": r['id'], "event": "done"})
        """#.write(to: script, atomically: true, encoding: .utf8)
    }

    func adapter(timeout: TimeInterval = 5) -> HeptapodPocketTurkishTTSAdapter {
        HeptapodPocketTurkishTTSAdapter(pythonExecutable: "python3", scriptURL: script, timeoutSeconds: timeout)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@Test
func pocketStreamsAllPCMAndReusesWorkerForVoiceChanges() async throws {
    let fixture = try PocketWorkerFixture()
    defer { fixture.remove() }
    let adapter = fixture.adapter()
    let first = try await adapter.synthesize("Merhaba.", languageCode: "tr-TR", voiceID: nil)
    let second = try await adapter.synthesize("Merhaba.", languageCode: "tr_TR", voiceID: "male_1")
    #expect(first.sampleRate == 24_000)
    #expect(first.pcm16 == Data([1, 0, 1, 0]))
    #expect(second.pcm16 == Data([2, 0, 2, 0]))
}

@Test(arguments: ["wrong-id", "bad-pcm", "crash"])
func pocketRejectsBrokenProtocolAndRestartsWorker(text: String) async throws {
    let fixture = try PocketWorkerFixture()
    defer { fixture.remove() }
    let adapter = fixture.adapter()
    await #expect(throws: (any Error).self) {
        try await adapter.synthesize(text, languageCode: "tr", voiceID: nil)
    }
    let next = try await adapter.synthesize("Yeni istek.", languageCode: "tr", voiceID: nil)
    #expect(next.pcm16 == Data([1, 0, 1, 0]))
}

@Test
func pocketRequestDeadlineIncludesStalledGeneration() async throws {
    let fixture = try PocketWorkerFixture()
    defer { fixture.remove() }
    let adapter = fixture.adapter(timeout: 0.75)
    do {
        _ = try await adapter.synthesize("timeout", languageCode: "tr", voiceID: nil)
        Issue.record("Expected stalled generation to time out")
    } catch HeptapodPocketTTSError.timedOut { }
    let next = try await adapter.synthesize("Yeni istek.", languageCode: "tr", voiceID: nil)
    #expect(next.pcm16.count == 4)
}

@Test
func cancellingPocketStreamStopsWorkerAndDoesNotPoisonNextRequest() async throws {
    let fixture = try PocketWorkerFixture()
    defer { fixture.remove() }
    let adapter = fixture.adapter()
    let firstPCM = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let task = Task {
        for try await _ in await adapter.synthesizeStream("stall", languageCode: "tr", voiceID: nil) {
            firstPCM.continuation.yield(())
        }
        try Task.checkCancellation()
    }
    var iterator = firstPCM.stream.makeAsyncIterator()
    _ = await iterator.next()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    let next = try await adapter.synthesize("Yeni istek.", languageCode: "tr", voiceID: nil)
    #expect(next.pcm16 == Data([1, 0, 1, 0]))
}

@Test
func pocketRejectsUnsupportedLanguageAndVoiceBeforeStartingModel() async throws {
    let adapter = HeptapodPocketTurkishTTSAdapter(scriptURL: URL(fileURLWithPath: "/missing-worker.py"))
    await #expect(throws: HeptapodPocketTTSError.self) { try await adapter.prepare(languageCode: "en") }
    await #expect(throws: HeptapodPocketTTSError.self) {
        try await adapter.synthesize("Merhaba.", languageCode: "tr", voiceID: "unknown")
    }
    let config = HeptapodPipelineConfiguration(
        speechRecognitionModelID: HeptapodModelDescriptor.nemotronStreamingASR.id,
        textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
        speechSynthesisModelID: HeptapodModelDescriptor.pocketTurkishTTS.id
    )
    #expect(HeptapodSpeechSwiftAdapterFactory.readiness(for: config).canRunInference)
    _ = try HeptapodSpeechSwiftAdapterFactory.makePipeline(configuration: config)
}
