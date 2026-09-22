import Foundation
import HeptapodLocalSpeechEngine
import NemotronStreamingASR

public actor HeptapodNemotronStreamingASRAdapter: HeptapodStreamingSpeechRecognizer {
    public static let defaultModelID = NemotronStreamingASRModel.defaultModelId
    public nonisolated let descriptor: HeptapodModelDescriptor

    private static let languageTagPattern = try! NSRegularExpression(
        pattern: "<[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})?>"
    )

    private let modelID: String
    private var model: NemotronStreamingASRModel?

    public init(
        descriptor: HeptapodModelDescriptor = .nemotronStreamingASR,
        modelID: String = HeptapodNemotronStreamingASRAdapter.defaultModelID
    ) {
        self.descriptor = descriptor
        self.modelID = modelID
    }

    public func prepare() async throws {
        let model = try await preparedModel()
        try model.warmUp()
    }

    public func transcribe(
        _ chunk: HeptapodAudioChunk,
        languageHint: String?
    ) async throws -> HeptapodTranscriptSegment? {
        let model = try await preparedModel()
        let audio = HeptapodSpeechSwiftAudioSamples.floatSamples(
            from: chunk,
            targetSampleRate: model.config.sampleRate
        )
        let text = Self.sanitizedTranscriptText(
            try model.transcribeAudio(
                audio,
                sampleRate: model.config.sampleRate,
                language: languageHint,
                padSilence: false
            )
        )

        guard text.isEmpty == false else {
            return nil
        }

        return HeptapodTranscriptSegment(
            text: text,
            languageCode: languageHint,
            isFinal: true
        )
    }

    public func finish(languageHint: String?) async throws -> HeptapodTranscriptSegment? {
        nil
    }

    public func reset() async {}

    public func openStreamingSession(
        languageHint: String?
    ) async throws -> any HeptapodStreamingRecognitionSession {
        let model = try await preparedModel()
        return NemotronStreamingRecognitionSession(
            session: try model.createSession(language: languageHint),
            sampleRate: model.config.sampleRate,
            languageCode: languageHint
        )
    }

    private func preparedModel() async throws -> NemotronStreamingASRModel {
        if let model {
            return model
        }

        let loaded = try await NemotronStreamingASRModel.fromPretrained(modelId: modelID)
        model = loaded
        return loaded
    }

    public static func sanitizedTranscriptText(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let sanitized = Self.languageTagPattern.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: ""
        )
        return sanitized.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

public final class NemotronStreamingRecognitionSession: HeptapodStreamingRecognitionSession, @unchecked Sendable {
    private let session: StreamingSession
    private let sampleRate: Int
    private let languageCode: String?
    private var finished = false

    fileprivate init(
        session: StreamingSession,
        sampleRate: Int,
        languageCode: String?
    ) {
        self.session = session
        self.sampleRate = sampleRate
        self.languageCode = languageCode
    }

    public func pushAudio(_ chunk: HeptapodAudioChunk) async throws -> [HeptapodTranscriptSegment] {
        guard finished == false else {
            return []
        }
        let samples = HeptapodSpeechSwiftAudioSamples.floatSamples(from: chunk, targetSampleRate: sampleRate)
        return try session.pushAudio(samples).compactMap { partial in
            let text = HeptapodNemotronStreamingASRAdapter.sanitizedTranscriptText(partial.text)
            guard text.isEmpty == false, partial.isFinal == false else {
                return nil
            }
            return HeptapodTranscriptSegment(
                text: text,
                languageCode: languageCode,
                isFinal: false
            )
        }
    }

    public func finishUtterance() async throws -> HeptapodTranscriptSegment? {
        guard finished == false else {
            return nil
        }
        finished = true
        let finals = try session.finalize()
        guard let final = finals.last(where: { $0.isFinal }) else {
            return nil
        }
        let text = HeptapodNemotronStreamingASRAdapter.sanitizedTranscriptText(final.text)
        guard text.isEmpty == false else {
            return nil
        }
        return HeptapodTranscriptSegment(
            text: text,
            languageCode: languageCode,
            isFinal: true
        )
    }

    public func abandonUtterance() async {
        finished = true
    }
}
