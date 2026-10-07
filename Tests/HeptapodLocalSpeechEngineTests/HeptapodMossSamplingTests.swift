import Foundation
import HeptapodLocalSpeechEngine
import HeptapodSpeechSwiftAdapters
import Testing

#if os(macOS)
@Test(.timeLimit(.minutes(1)))
func mossSamplingAdapterPassesFixedDefaultToPersistentWorker() async throws {
    let script = try makeMossSamplingWorker()
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let adapter = HeptapodMossTTSNanoAdapter(
        pythonExecutable: "python3",
        scriptURL: script
    )

    for requestNumber in 1...2 {
        let speech = try await adapter.synthesize("herkes.", languageCode: "tr", voiceID: nil)
        #expect(speech.pcm16 == Data([1, 0, UInt8(requestNumber), 0, 9, 0]))
        #expect(speech.sampleRate == 48_000)
        #expect(speech.languageCode == "tr")
    }
}

@Test(.timeLimit(.minutes(1)), arguments: HeptapodMossTTSSampleMode.allCases)
func mossSamplingAdapterForwardsEachModeWithoutChangingPCM(_ mode: HeptapodMossTTSSampleMode) async throws {
    let script = try makeMossSamplingWorker()
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let adapter = HeptapodMossTTSNanoAdapter(
        pythonExecutable: "python3",
        scriptURL: script,
        sampleMode: mode
    )
    let modeID: UInt8 = mode == .fixed ? 1 : (mode == .full ? 2 : 3)

    for requestNumber in 1...2 {
        let speech = try await adapter.synthesize("herkes.", languageCode: "tr", voiceID: nil)
        #expect(speech.pcm16 == Data([modeID, 0, UInt8(requestNumber), 0, 9, 0]))
        #expect(speech.sampleRate == 48_000)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: HeptapodMossTTSSampleMode.allCases)
func mossSamplingFactoryForwardsModeToStreamingWorker(_ mode: HeptapodMossTTSSampleMode) async throws {
    let script = try makeMossSamplingWorker()
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let pipeline = try HeptapodSpeechSwiftAdapterFactory.makePipeline(
        configuration: HeptapodPipelineConfiguration(
            speechRecognitionModelID: HeptapodModelDescriptor.qwenASRCompact.id,
            textTranslationModelID: HeptapodModelDescriptor.madladTranslator.id,
            speechSynthesisModelID: HeptapodModelDescriptor.mossTTSNano.id
        ),
        mossPythonExecutable: "python3",
        mossScriptURL: script,
        mossSampleMode: mode
    )
    let translation = HeptapodTranslatedText(
        sourceText: "everyone.",
        translatedText: "herkes.",
        sourceLanguageCode: "en",
        targetLanguageCode: "tr"
    )
    let stream = await pipeline.synthesizeStream(translation)
    var chunks: [HeptapodSynthesizedSpeech] = []
    for try await chunk in stream {
        chunks.append(chunk)
    }
    let modeID: UInt8 = mode == .fixed ? 1 : (mode == .full ? 2 : 3)
    #expect(chunks.map(\.pcm16) == [Data([modeID, 0, 1, 0]), Data([9, 0])])
    #expect(chunks.allSatisfy { $0.sampleRate == 48_000 && $0.languageCode == "tr" })
}

private func makeMossSamplingWorker() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("heptapod-moss-sampling-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("worker.py")
    let source = #"""
    import base64
    import json
    import sys

    arguments = sys.argv[1:]
    mode = None
    if "--sample-mode" in arguments:
        mode = arguments[arguments.index("--sample-mode") + 1]
    print(json.dumps({"ready": True, "sample_rate": 48000, "voices": ["Ava"]}), flush=True)
    for request_number, line in enumerate(sys.stdin, start=1):
        request = json.loads(line)
        if mode not in ("fixed", "full", "greedy"):
            print(json.dumps({"id": request["id"], "event": "error", "error": "Missing or invalid --sample-mode"}), flush=True)
            continue
        mode_id = {"fixed": 1, "full": 2, "greedy": 3}[mode]
        for pcm in (bytes([mode_id, 0, request_number, 0]), bytes([9, 0])):
            print(json.dumps({"id": request["id"], "event": "audio", "sample_rate": 48000, "pcm16": base64.b64encode(pcm).decode("ascii")}), flush=True)
        print(json.dumps({"id": request["id"], "event": "done"}), flush=True)
    """#
    try source.write(to: script, atomically: true, encoding: .utf8)
    return script
}
#endif
