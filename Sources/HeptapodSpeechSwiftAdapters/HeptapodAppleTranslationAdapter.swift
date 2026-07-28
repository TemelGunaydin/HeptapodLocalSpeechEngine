import Foundation
import HeptapodLocalSpeechEngine

public enum HeptapodAppleTranslationStrategy: String, Sendable {
    case lowLatency
    case highFidelity
}

#if canImport(Translation)
import Translation

public actor HeptapodAppleTranslationAdapter: HeptapodTextTranslator {
    public nonisolated let descriptor: HeptapodModelDescriptor

    private let strategy: HeptapodAppleTranslationStrategy
    private var workers: [LanguagePair: AppleTranslationWorker] = [:]

    public init(
        descriptor: HeptapodModelDescriptor = .appleTranslation,
        strategy: HeptapodAppleTranslationStrategy = .highFidelity
    ) {
        self.descriptor = descriptor
        self.strategy = strategy
    }

    public func prepare() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw HeptapodAppleTranslationError.unsupportedOperatingSystem
        }
    }

    public func translate(
        _ text: String,
        sourceLanguageCode: String?,
        targetLanguageCode: String
    ) async throws -> HeptapodTranslatedText {
        let sourceText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sourceText.isEmpty == false else {
            throw HeptapodAppleTranslationError.emptySourceText
        }
        guard let sourceLanguageCode, sourceLanguageCode.isEmpty == false else {
            throw HeptapodAppleTranslationError.sourceLanguageRequired
        }
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw HeptapodAppleTranslationError.unsupportedOperatingSystem
        }

        let pair = LanguagePair(
            sourceCode: Self.normalizedLanguageCode(sourceLanguageCode),
            targetCode: Self.normalizedLanguageCode(targetLanguageCode)
        )
        guard pair.sourceCode.isEmpty == false, pair.targetCode.isEmpty == false else {
            throw HeptapodAppleTranslationError.invalidLanguagePair(
                source: sourceLanguageCode,
                target: targetLanguageCode
            )
        }

        if pair.sourceCode == pair.targetCode {
            return HeptapodTranslatedText(
                sourceText: sourceText,
                translatedText: sourceText,
                sourceLanguageCode: sourceLanguageCode,
                targetLanguageCode: targetLanguageCode
            )
        }

        let worker = try await preparedWorker(for: pair)
        let translatedText = try await worker.translate(sourceText)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return HeptapodTranslatedText(
            sourceText: sourceText,
            translatedText: translatedText,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode
        )
    }

    @available(macOS 26.0, iOS 26.0, *)
    private func preparedWorker(for pair: LanguagePair) async throws -> AppleTranslationWorker {
        if let worker = workers[pair] {
            return worker
        }

        let source = Locale.Language(identifier: pair.sourceCode)
        let target = Locale.Language(identifier: pair.targetCode)
        let status: LanguageAvailability.Status
        if #available(macOS 26.4, iOS 26.4, *) {
            let availability = LanguageAvailability(
                preferredStrategy: strategy.translationSessionStrategy
            )
            status = await availability.status(from: source, to: target)
        } else {
            let availability = LanguageAvailability()
            status = await availability.status(from: source, to: target)
        }

        switch status {
        case .installed:
            break
        case .supported:
            throw HeptapodAppleTranslationError.languagePairNotInstalled(
                source: pair.sourceCode,
                target: pair.targetCode
            )
        case .unsupported:
            throw HeptapodAppleTranslationError.unsupportedLanguagePair(
                source: pair.sourceCode,
                target: pair.targetCode
            )
        @unknown default:
            throw HeptapodAppleTranslationError.unsupportedLanguagePair(
                source: pair.sourceCode,
                target: pair.targetCode
            )
        }

        let worker = AppleTranslationWorker(
            source: source,
            target: target,
            strategy: strategy
        )
        workers[pair] = worker
        return worker
    }

    private static func normalizedLanguageCode(_ code: String) -> String {
        let identifier = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        guard identifier.isEmpty == false else {
            return ""
        }
        return Locale.Language(identifier: identifier).minimalIdentifier
    }
}

public enum HeptapodAppleTranslationError: LocalizedError, Equatable, Sendable {
    case emptySourceText
    case invalidLanguagePair(source: String, target: String)
    case languagePairNotInstalled(source: String, target: String)
    case sourceLanguageRequired
    case unsupportedLanguagePair(source: String, target: String)
    case unsupportedOperatingSystem

    public var errorDescription: String? {
        switch self {
        case .emptySourceText:
            "Apple Translation received empty source text."
        case .invalidLanguagePair(let source, let target):
            "Invalid Apple Translation language pair: \(source) -> \(target)."
        case .languagePairNotInstalled(let source, let target):
            "Apple Translation supports \(source) -> \(target), but its language assets are not installed. Install both languages in the system Translation settings and run the demo again."
        case .sourceLanguageRequired:
            "Apple Translation requires a source language code."
        case .unsupportedLanguagePair(let source, let target):
            "Apple Translation does not support \(source) -> \(target) on this device."
        case .unsupportedOperatingSystem:
            "The headless Apple Translation adapter requires macOS 26.0 or iOS 26.0."
        }
    }
}

private struct LanguagePair: Hashable, Sendable {
    let sourceCode: String
    let targetCode: String
}

private struct AppleTranslationRequest: Sendable {
    let sourceText: String
    let continuation: CheckedContinuation<String, any Error>
}

private final class AppleTranslationWorker: Sendable {
    private let continuation: AsyncStream<AppleTranslationRequest>.Continuation
    private let task: Task<Void, Never>

    @available(macOS 26.0, iOS 26.0, *)
    init(
        source: Locale.Language,
        target: Locale.Language,
        strategy: HeptapodAppleTranslationStrategy
    ) {
        let pair = AsyncStream<AppleTranslationRequest>.makeStream()
        continuation = pair.continuation
        task = Task {
            if #available(macOS 26.4, iOS 26.4, *) {
                let session = TranslationSession(
                    installedSource: source,
                    target: target,
                    preferredStrategy: strategy.translationSessionStrategy
                )
                for await request in pair.stream {
                    do {
                        let response = try await session.translate(request.sourceText)
                        request.continuation.resume(returning: response.targetText)
                    } catch {
                        request.continuation.resume(throwing: error)
                    }
                }
            } else {
                let session = TranslationSession(installedSource: source, target: target)
                for await request in pair.stream {
                    do {
                        let response = try await session.translate(request.sourceText)
                        request.continuation.resume(returning: response.targetText)
                    } catch {
                        request.continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    deinit {
        continuation.finish()
        task.cancel()
    }

    func translate(_ sourceText: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation.yield(
                AppleTranslationRequest(
                    sourceText: sourceText,
                    continuation: continuation
                )
            )
        }
    }
}

@available(macOS 26.4, iOS 26.4, *)
private extension HeptapodAppleTranslationStrategy {
    var translationSessionStrategy: TranslationSession.Strategy {
        switch self {
        case .lowLatency:
            .lowLatency
        case .highFidelity:
            .highFidelity
        }
    }
}
#endif
