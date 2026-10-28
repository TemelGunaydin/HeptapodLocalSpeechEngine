import Testing
@testable import HeptapodLiveSpeechDemo

@Test
func realtimeProfileSelectsStreamingEnglishASRAndAcceptedTurkishVoice() throws {
    let options = try DemoOptions(arguments: ["--latency", "realtime", "--to", "tr-TR"])
    #expect(options.asrPreset == .nemotron)
    #expect(options.ttsBackend == .pocket)
    #expect(options.pocketVoice == "female_2")
    #expect(options.ttsPythonExecutable == ".venv-pocket-tts/bin/python")
    #expect(options.chunkDurationSeconds == 1.0)
    #expect(options.endpointingConfiguration.flushOnTerminalPunctuation)
    if #available(macOS 26.0, *) { #expect(options.mtBackend == .apple) }
}

@Test(arguments: [true, false])
func realtimeProfilePreservesExplicitOverridesRegardlessOfArgumentOrder(profileFirst: Bool) throws {
    let profile = ["--latency", "realtime"]
    let overrides = ["--asr", "quality", "--mt", "madlad", "--tts", "moss", "--chunk-duration", "0.75", "--no-asr-stabilization"]
    let options = try DemoOptions(arguments: profileFirst ? profile + overrides : overrides + profile)
    #expect(options.asrPreset == .quality)
    #expect(options.mtBackend == .madlad)
    #expect(options.ttsBackend == .moss)
    #expect(options.chunkDurationSeconds == 0.75)
    #expect(!options.usesASRStabilization)
}

@Test
func realtimeProfileDoesNotSelectEnglishOnlyASRForTurkishInput() throws {
    let options = try DemoOptions(arguments: ["--latency", "realtime", "--from", "tr", "--to", "en"])
    #expect(options.asrPreset == .compact)
    #expect(options.ttsBackend == .kokoro)
}

@Test
func pocketVoiceSelectionRejectsUnknownVoices() throws {
    #expect(try DemoOptions(arguments: ["--pocket-voice", "male_1"]).pocketVoice == "male_1")
    #expect(throws: (any Error).self) { try DemoOptions(arguments: ["--pocket-voice", "Ava"]) }
}
