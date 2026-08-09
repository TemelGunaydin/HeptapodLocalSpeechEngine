import Foundation

public struct HeptapodTranslationContextItem: Equatable, Sendable {
    public let sourceText: String
    public let acceptedTranslation: String
    public let sourceLanguageCode: String?
    public let targetLanguageCode: String?

    public init(
        sourceText: String,
        acceptedTranslation: String,
        sourceLanguageCode: String? = nil,
        targetLanguageCode: String? = nil
    ) {
        self.sourceText = sourceText
        self.acceptedTranslation = acceptedTranslation
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
    }
}

public protocol HeptapodTranslationPostEditor: Sendable {
    func prepare() async throws

    func edit(
        _ draft: HeptapodTranslatedText,
        context: [HeptapodTranslationContextItem]
    ) async throws -> String
}

public extension HeptapodTranslationPostEditor {
    func prepare() async throws {}
}

public enum HeptapodPostEditFailurePolicy: Sendable {
    case useDraft
    case fail
}

public actor HeptapodPostEditingTranslator: HeptapodTextTranslator {
    public nonisolated let descriptor: HeptapodModelDescriptor

    private let translator: any HeptapodTextTranslator
    private let postEditor: any HeptapodTranslationPostEditor
    private let contextLimit: Int
    private let failurePolicy: HeptapodPostEditFailurePolicy
    private var history: [HeptapodTranslationContextItem] = []
    private var isPostEditorReady = true
    private var isTranslationInProgress = false
    private var translationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        translator: any HeptapodTextTranslator,
        postEditor: any HeptapodTranslationPostEditor,
        contextLimit: Int = 2,
        failurePolicy: HeptapodPostEditFailurePolicy = .useDraft
    ) {
        self.descriptor = translator.descriptor
        self.translator = translator
        self.postEditor = postEditor
        self.contextLimit = max(0, contextLimit)
        self.failurePolicy = failurePolicy
    }

    public func prepare() async throws {
        try await translator.prepare()
        do {
            try await postEditor.prepare()
            isPostEditorReady = true
        } catch {
            switch failurePolicy {
            case .useDraft:
                isPostEditorReady = false
            case .fail:
                throw error
            }
        }
    }

    public func translate(
        _ text: String,
        sourceLanguageCode: String?,
        targetLanguageCode: String
    ) async throws -> HeptapodTranslatedText {
        await acquireTranslationSlot()
        defer { releaseTranslationSlot() }
        try Task.checkCancellation()

        let draft = try await translator.translate(
            text,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode
        )

        let editedText: String
        if isPostEditorReady {
            do {
                let candidate = try await postEditor.edit(
                    draft,
                    context: matchingContext(for: draft)
                )
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard candidate.isEmpty == false else {
                    throw HeptapodPostEditError.emptyResult
                }
                editedText = candidate
            } catch {
                switch failurePolicy {
                case .useDraft:
                    editedText = draft.translatedText
                case .fail:
                    throw error
                }
            }
        } else {
            editedText = draft.translatedText
        }

        let result = HeptapodTranslatedText(
            sourceText: draft.sourceText,
            translatedText: editedText,
            sourceLanguageCode: draft.sourceLanguageCode,
            targetLanguageCode: draft.targetLanguageCode
        )
        remember(result)
        return result
    }

    public func resetContext() {
        history.removeAll(keepingCapacity: true)
    }

    public func context() -> [HeptapodTranslationContextItem] {
        history
    }

    private func acquireTranslationSlot() async {
        guard isTranslationInProgress else {
            isTranslationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            translationWaiters.append(continuation)
        }
    }

    private func releaseTranslationSlot() {
        guard translationWaiters.isEmpty == false else {
            isTranslationInProgress = false
            return
        }
        translationWaiters.removeFirst().resume()
    }

    private func matchingContext(
        for draft: HeptapodTranslatedText
    ) -> [HeptapodTranslationContextItem] {
        history.filter { item in
            languageCodesMatch(item.targetLanguageCode, draft.targetLanguageCode)
                && languageCodesMatchWhenKnown(
                    item.sourceLanguageCode,
                    draft.sourceLanguageCode
                )
        }
    }

    private func remember(_ translation: HeptapodTranslatedText) {
        guard contextLimit > 0 else {
            return
        }
        history.append(
            HeptapodTranslationContextItem(
                sourceText: translation.sourceText,
                acceptedTranslation: translation.translatedText,
                sourceLanguageCode: translation.sourceLanguageCode,
                targetLanguageCode: translation.targetLanguageCode
            )
        )
        if history.count > contextLimit {
            history.removeFirst(history.count - contextLimit)
        }
    }
}

public enum HeptapodPostEditError: LocalizedError, Sendable {
    case emptyResult

    public var errorDescription: String? {
        switch self {
        case .emptyResult:
            "Translation post-edit returned empty text."
        }
    }
}

public struct HeptapodTranslationReplacementRule: Equatable, Sendable {
    public let sourceLanguageCode: String
    public let targetLanguageCode: String
    public let sourcePhrase: String
    public let draftPhrase: String
    public let replacement: String
    public let requiresMatchingContext: Bool

    public init(
        sourceLanguageCode: String,
        targetLanguageCode: String,
        sourcePhrase: String,
        draftPhrase: String,
        replacement: String,
        requiresMatchingContext: Bool = false
    ) {
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
        self.sourcePhrase = sourcePhrase
        self.draftPhrase = draftPhrase
        self.replacement = replacement
        self.requiresMatchingContext = requiresMatchingContext
    }

    fileprivate func apply(
        to draft: HeptapodTranslatedText,
        context: [HeptapodTranslationContextItem]
    ) -> String? {
        guard languageCodesMatch(draft.sourceLanguageCode, sourceLanguageCode),
              languageCodesMatch(draft.targetLanguageCode, targetLanguageCode),
              sourceContainsPhrase(draft.sourceText),
              requiresMatchingContext == false || hasMatchingContext(context),
              let replaced = replacingDraftPhrase(in: draft.translatedText) else {
            return nil
        }
        return replaced
    }

    private func sourceContainsPhrase(_ sourceText: String) -> Bool {
        let phrase = NSRegularExpression.escapedPattern(for: sourcePhrase)
        let pattern = "(?<![\\p{L}\\p{N}])\(phrase)(?![\\p{L}\\p{N}])"
        return sourceText.range(
            of: pattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func hasMatchingContext(
        _ context: [HeptapodTranslationContextItem]
    ) -> Bool {
        context.reversed().contains { item in
            languageCodesMatchWhenKnown(item.sourceLanguageCode, sourceLanguageCode)
                && languageCodesMatchWhenKnown(item.targetLanguageCode, targetLanguageCode)
                && sourceContainsPhrase(item.sourceText)
                && item.acceptedTranslation.range(
                    of: replacement,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil
        }
    }

    private func replacingDraftPhrase(in text: String) -> String? {
        let phrase = NSRegularExpression.escapedPattern(for: draftPhrase)
        let pattern = "(?<![\\p{L}\\p{N}])\(phrase)(?![\\p{L}\\p{N}])"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ) != nil else {
            return nil
        }
        return expression.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }
}

public struct HeptapodTerminologyPostEditor: HeptapodTranslationPostEditor {
    public let rules: [HeptapodTranslationReplacementRule]

    public init(rules: [HeptapodTranslationReplacementRule]) {
        self.rules = rules
    }

    public func edit(
        _ draft: HeptapodTranslatedText,
        context: [HeptapodTranslationContextItem]
    ) async throws -> String {
        var edited = draft
        for rule in rules {
            guard let replacement = rule.apply(to: edited, context: context) else {
                continue
            }
            edited = HeptapodTranslatedText(
                sourceText: edited.sourceText,
                translatedText: replacement,
                sourceLanguageCode: edited.sourceLanguageCode,
                targetLanguageCode: edited.targetLanguageCode
            )
        }
        return edited.translatedText
    }
}

public extension HeptapodTerminologyPostEditor {
    static func liveSpeechProfile(
        sourceLanguageCode: String?,
        targetLanguageCode: String
    ) -> HeptapodTerminologyPostEditor? {
        guard languageCodesMatch(sourceLanguageCode, "en"),
              languageCodesMatch(targetLanguageCode, "tr") else {
            return nil
        }
        return .englishToTurkishLiveSpeech
    }

    static let englishToTurkishLiveSpeech = HeptapodTerminologyPostEditor(
        rules: [
            rule("translated voice should sound clear and natural", "Çevrilen ses", "Çevrilmiş ses"),
            rule("translated voice should sound clear and natural", "net ve doğal gelmelidir", "net ve doğal duyulmalı"),
            rule("first run", "İlk koşunun", "İlk çalıştırmanın"),
            rule("first run", "ilk koşunun", "ilk çalıştırmanın"),
            rule("trade for lower latency", "Daha düşük gecikme için", "Daha düşük gecikme uğruna"),
            rule("trade for lower latency", "ne kadar kaliteyi takas etmeye", "ne kadar kaliteden ödün vermeye"),
            rule("persistent worker", "Kalıcı çalışan", "Kalıcı worker"),
            rule("persistent worker", "kalıcı çalışan", "kalıcı worker"),
            rule("stable transcript prefixes", "sabit transkript önekleri", "kararlı transkript önekleri"),
            rule("speech synthesis", "Konuşma sentezi", "Ses sentezi"),
            rule("local version", "yerel versiyonun", "yerel sürümün"),
            rule("audio output format", "ses çıkışı formatı", "ses çıkış biçimi"),
            rule("shortened the segments", "bölümleri kısalttık", "segmentleri kısalttık"),
            rule(
                "translated speech could begin",
                "tercüme edilen konuşmanın başlayabilmesi için",
                "çevrilmiş konuşma başlayabilsin diye"
            ),
            contextRule("segment", "Bölüm", "Segment"),
            contextRule("segment", "bölüm", "segment"),
            contextRule("segments", "Bölümler", "Segmentler"),
            contextRule("segments", "bölümler", "segmentler"),
            contextRule("transcript", "konuşma metni", "transkript"),
            contextRule("transcripts", "konuşma metinleri", "transkriptler"),
            contextRule("live translation", "canlı tercüme", "canlı çeviri"),
            contextRule("speech synthesis", "Konuşma sentezi", "Ses sentezi"),
            contextRule("speech synthesis", "konuşma sentezi", "ses sentezi")
        ]
    )

    private static func rule(
        _ sourcePhrase: String,
        _ draftPhrase: String,
        _ replacement: String
    ) -> HeptapodTranslationReplacementRule {
        HeptapodTranslationReplacementRule(
            sourceLanguageCode: "en",
            targetLanguageCode: "tr",
            sourcePhrase: sourcePhrase,
            draftPhrase: draftPhrase,
            replacement: replacement
        )
    }

    private static func contextRule(
        _ sourcePhrase: String,
        _ draftPhrase: String,
        _ replacement: String
    ) -> HeptapodTranslationReplacementRule {
        HeptapodTranslationReplacementRule(
            sourceLanguageCode: "en",
            targetLanguageCode: "tr",
            sourcePhrase: sourcePhrase,
            draftPhrase: draftPhrase,
            replacement: replacement,
            requiresMatchingContext: true
        )
    }
}

private func languageCodesMatch(_ lhs: String?, _ rhs: String?) -> Bool {
    guard let lhsRoot = languageRoot(lhs), let rhsRoot = languageRoot(rhs) else {
        return false
    }
    return lhsRoot == rhsRoot
}

private func languageCodesMatchWhenKnown(_ lhs: String?, _ rhs: String?) -> Bool {
    guard lhs != nil, rhs != nil else {
        return true
    }
    return languageCodesMatch(lhs, rhs)
}

private func languageRoot(_ languageCode: String?) -> String? {
    languageCode?
        .replacingOccurrences(of: "_", with: "-")
        .split(separator: "-", maxSplits: 1)
        .first
        .map { String($0).lowercased() }
}
