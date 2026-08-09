import Foundation

public struct HeptapodTranslationContextItem: Equatable, Sendable {
    public let sourceText: String
    public let acceptedTranslation: String

    public init(sourceText: String, acceptedTranslation: String) {
        self.sourceText = sourceText
        self.acceptedTranslation = acceptedTranslation
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
        let draft = try await translator.translate(
            text,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode
        )

        let editedText: String
        if isPostEditorReady {
            do {
                let candidate = try await postEditor.edit(draft, context: history)
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

    private func remember(_ translation: HeptapodTranslatedText) {
        guard contextLimit > 0 else {
            return
        }
        history.append(
            HeptapodTranslationContextItem(
                sourceText: translation.sourceText,
                acceptedTranslation: translation.translatedText
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

    public init(
        sourceLanguageCode: String,
        targetLanguageCode: String,
        sourcePhrase: String,
        draftPhrase: String,
        replacement: String
    ) {
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
        self.sourcePhrase = sourcePhrase
        self.draftPhrase = draftPhrase
        self.replacement = replacement
    }

    fileprivate func apply(to draft: HeptapodTranslatedText) -> String? {
        guard languageRoot(draft.sourceLanguageCode) == languageRoot(sourceLanguageCode),
              languageRoot(draft.targetLanguageCode) == languageRoot(targetLanguageCode),
              sourceContainsPhrase(draft.sourceText),
              draft.translatedText.contains(draftPhrase) else {
            return nil
        }
        return draft.translatedText.replacingOccurrences(of: draftPhrase, with: replacement)
    }

    private func sourceContainsPhrase(_ sourceText: String) -> Bool {
        let phrase = NSRegularExpression.escapedPattern(for: sourcePhrase)
        let pattern = "(?<![\\p{L}\\p{N}])\(phrase)(?![\\p{L}\\p{N}])"
        return sourceText.range(
            of: pattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func languageRoot(_ languageCode: String?) -> String? {
        languageCode?
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", maxSplits: 1)
            .first
            .map { String($0).lowercased() }
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
            guard let replacement = rule.apply(to: edited) else {
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
            )
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
}
