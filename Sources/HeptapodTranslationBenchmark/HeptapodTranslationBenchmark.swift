import Foundation
import HeptapodLocalSpeechEngine
import HeptapodSpeechSwiftAdapters
#if canImport(FoundationModels)
import FoundationModels
#endif

@main
struct HeptapodTranslationBenchmark {
    static func main() async {
        do {
            let options = try BenchmarkOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.printsHelp {
                printUsage()
                return
            }

            let fixtureData = try Data(contentsOf: options.inputURL)
            let fixture = try JSONDecoder().decode(TranslationFixture.self, from: fixtureData)
            let translator = try makeTranslator(options: options)
            let postEditor = try makePostEditor(options: options)
            let clock = ContinuousClock()

            let preparationStarted = clock.now
            try await translator.prepare()
            let preparationSeconds = seconds(preparationStarted.duration(to: clock.now))

            var postEditPreparationSeconds: Double?
            if let postEditor {
                let postEditPreparationStarted = clock.now
                try await postEditor.prepare(targetLanguageCode: fixture.targetLanguage)
                postEditPreparationSeconds = seconds(postEditPreparationStarted.duration(to: clock.now))
            }

            var warmupSeconds: Double?
            if options.usesWarmup, let warmupSource = fixture.cases.first?.source {
                let warmupStarted = clock.now
                _ = try await translator.translate(
                    warmupSource,
                    sourceLanguageCode: fixture.sourceLanguage,
                    targetLanguageCode: fixture.targetLanguage
                )
                warmupSeconds = seconds(warmupStarted.duration(to: clock.now))
            }

            var results: [TranslationBenchmarkItemResult] = []
            var context: [BenchmarkTranslationContextItem] = []
            results.reserveCapacity(fixture.cases.count)
            for item in fixture.cases {
                let started = clock.now
                let draft = try await translator.translate(
                    item.source,
                    sourceLanguageCode: fixture.sourceLanguage,
                    targetLanguageCode: fixture.targetLanguage
                )
                let translationSeconds = seconds(started.duration(to: clock.now))

                let finalTranslation: String
                let postEditSeconds: Double?
                if let postEditor {
                    let postEditStarted = clock.now
                    finalTranslation = try await postEditor.edit(
                        sourceText: item.source,
                        draftTranslation: draft.translatedText,
                        sourceLanguageCode: fixture.sourceLanguage,
                        targetLanguageCode: fixture.targetLanguage,
                        context: Array(context.suffix(options.postEditContextLimit))
                    )
                    postEditSeconds = seconds(postEditStarted.duration(to: clock.now))
                } else {
                    finalTranslation = draft.translatedText
                    postEditSeconds = nil
                }

                context.append(
                    BenchmarkTranslationContextItem(
                        sourceText: item.source,
                        acceptedTranslation: finalTranslation
                    )
                )
                results.append(
                    TranslationBenchmarkItemResult(
                        id: item.id,
                        category: item.category,
                        source: item.source,
                        reference: item.reference,
                        draftTranslation: postEditor == nil ? nil : draft.translatedText,
                        translation: finalTranslation,
                        translationSeconds: translationSeconds,
                        postEditSeconds: postEditSeconds
                    )
                )
            }

            let translationSeconds = results.map(\.translationSeconds)
            let postEditSeconds = results.compactMap(\.postEditSeconds)
            let report = TranslationBenchmarkReport(
                createdAt: ISO8601DateFormatter().string(from: Date()),
                backend: options.backend.rawValue,
                descriptorID: translator.descriptor.id,
                postEditBackend: options.postEditBackend.rawValue,
                postEditContextLimit: options.postEditContextLimit,
                sourceLanguage: fixture.sourceLanguage,
                targetLanguage: fixture.targetLanguage,
                preparationSeconds: preparationSeconds,
                postEditPreparationSeconds: postEditPreparationSeconds,
                warmupSeconds: warmupSeconds,
                averageTranslationSeconds: translationSeconds.reduce(0, +) / Double(max(1, translationSeconds.count)),
                averagePostEditSeconds: average(postEditSeconds),
                maximumTranslationSeconds: translationSeconds.max() ?? 0,
                maximumPostEditSeconds: postEditSeconds.max(),
                results: results
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let output = try encoder.encode(report)

            if let outputURL = options.outputURL {
                try output.write(to: outputURL, options: .atomic)
                print("Wrote \(results.count) translations to \(outputURL.path)")
            } else {
                FileHandle.standardOutput.write(output)
                FileHandle.standardOutput.write(Data([0x0A]))
            }
        } catch {
            fputs("Translation benchmark failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func makeTranslator(options: BenchmarkOptions) throws -> any HeptapodTextTranslator {
        switch options.backend {
        case .madlad:
            HeptapodMADLADTranslatorAdapter()
        case .translateGemma:
            HeptapodTranslateGemmaTranslatorAdapter(
                pythonExecutable: options.translateGemmaPythonExecutable,
                scriptURL: options.translateGemmaScriptURL,
                modelID: options.translateGemmaModelID
            )
        case .apple:
            #if canImport(Translation)
            HeptapodAppleTranslationAdapter()
            #else
            throw BenchmarkError.appleTranslationUnavailable
            #endif
        }
    }

    private static func makePostEditor(options: BenchmarkOptions) throws -> (any TranslationPostEditor)? {
        switch options.postEditBackend {
        case .none:
            return nil
        case .glossary:
            return GlossaryBenchmarkPostEditor()
        case .appleFoundation:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, iOS 26.0, *) {
                return AppleFoundationModelsTurkishPostEditor()
            }
            #endif
            throw BenchmarkError.appleFoundationModelsUnavailable("The FoundationModels framework requires macOS 26 or newer.")
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func average(_ values: [Double]) -> Double? {
        guard values.isEmpty == false else {
            return nil
        }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func printUsage() {
        print("""
        Usage:
          HeptapodTranslationBenchmark \
            --backend <apple|madlad|translategemma> \
            --input Experiments/Fixtures/en-tr-translation-quality.json \
            [--output /tmp/translations.json]

        Post-edit options:
          --postedit <none|glossary|apple-foundation>
                             Default: none.
          --postedit-context <count>
                             Previous accepted sentence pairs. Default: 2.

        TranslateGemma options:
          --python <path>    Default: .venv-translategemma/bin/python
          --script <path>    Default: Tools/translategemma_mlx_translation.py
          --model <id>       Default: mlx-community/translategemma-4b-it-4bit

        General options:
          --no-warmup        Keep the first inference in measured results.
          --help             Show this message.
        """)
    }
}

private struct TranslationFixture: Decodable {
    let sourceLanguage: String
    let targetLanguage: String
    let cases: [TranslationFixtureItem]

    enum CodingKeys: String, CodingKey {
        case sourceLanguage = "source_language"
        case targetLanguage = "target_language"
        case cases
    }
}

private struct TranslationFixtureItem: Decodable {
    let id: String
    let category: String
    let source: String
    let reference: String
}

private struct TranslationBenchmarkReport: Encodable {
    let createdAt: String
    let backend: String
    let descriptorID: String
    let postEditBackend: String
    let postEditContextLimit: Int
    let sourceLanguage: String
    let targetLanguage: String
    let preparationSeconds: Double
    let postEditPreparationSeconds: Double?
    let warmupSeconds: Double?
    let averageTranslationSeconds: Double
    let averagePostEditSeconds: Double?
    let maximumTranslationSeconds: Double
    let maximumPostEditSeconds: Double?
    let results: [TranslationBenchmarkItemResult]

    enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
        case backend
        case descriptorID = "descriptor_id"
        case postEditBackend = "post_edit_backend"
        case postEditContextLimit = "post_edit_context_limit"
        case sourceLanguage = "source_language"
        case targetLanguage = "target_language"
        case preparationSeconds = "preparation_seconds"
        case postEditPreparationSeconds = "post_edit_preparation_seconds"
        case warmupSeconds = "warmup_seconds"
        case averageTranslationSeconds = "average_translation_seconds"
        case averagePostEditSeconds = "average_post_edit_seconds"
        case maximumTranslationSeconds = "maximum_translation_seconds"
        case maximumPostEditSeconds = "maximum_post_edit_seconds"
        case results
    }
}

private struct TranslationBenchmarkItemResult: Encodable {
    let id: String
    let category: String
    let source: String
    let reference: String
    let draftTranslation: String?
    let translation: String
    let translationSeconds: Double
    let postEditSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case category
        case source
        case reference
        case draftTranslation = "draft_translation"
        case translation
        case translationSeconds = "translation_seconds"
        case postEditSeconds = "post_edit_seconds"
    }
}

private struct BenchmarkOptions {
    let backend: TranslationBackend
    let inputURL: URL
    let outputURL: URL?
    let usesWarmup: Bool
    let printsHelp: Bool
    let postEditBackend: PostEditBackend
    let postEditContextLimit: Int
    let translateGemmaPythonExecutable: String
    let translateGemmaScriptURL: URL
    let translateGemmaModelID: String

    init(arguments: [String]) throws {
        var backend: TranslationBackend?
        var inputURL: URL?
        var outputURL: URL?
        var usesWarmup = true
        var printsHelp = false
        var postEditBackend = PostEditBackend.none
        var postEditContextLimit = 2
        var pythonExecutable = ".venv-translategemma/bin/python"
        var scriptURL = URL(fileURLWithPath: "Tools/translategemma_mlx_translation.py")
        var modelID = HeptapodTranslateGemmaTranslatorAdapter.defaultModelID

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--backend":
                let rawValue = try Self.value(after: argument, in: arguments, at: &index)
                guard let parsed = TranslationBackend(rawValue: rawValue.lowercased()) else {
                    throw BenchmarkError.invalidBackend(rawValue)
                }
                backend = parsed
            case "--input":
                inputURL = URL(fileURLWithPath: try Self.value(after: argument, in: arguments, at: &index))
            case "--output":
                outputURL = URL(fileURLWithPath: try Self.value(after: argument, in: arguments, at: &index))
            case "--postedit":
                let rawValue = try Self.value(after: argument, in: arguments, at: &index)
                guard let parsed = PostEditBackend(rawValue: rawValue.lowercased()) else {
                    throw BenchmarkError.invalidPostEditBackend(rawValue)
                }
                postEditBackend = parsed
            case "--postedit-context":
                let rawValue = try Self.value(after: argument, in: arguments, at: &index)
                guard let value = Int(rawValue), (0...8).contains(value) else {
                    throw BenchmarkError.invalidPostEditContext(rawValue)
                }
                postEditContextLimit = value
            case "--python":
                pythonExecutable = try Self.value(after: argument, in: arguments, at: &index)
            case "--script":
                scriptURL = URL(fileURLWithPath: try Self.value(after: argument, in: arguments, at: &index))
            case "--model":
                modelID = try Self.value(after: argument, in: arguments, at: &index)
            case "--no-warmup":
                usesWarmup = false
            case "--help", "-h":
                printsHelp = true
            default:
                throw BenchmarkError.unknownArgument(argument)
            }
            index += 1
        }

        if printsHelp {
            self.backend = backend ?? .apple
            self.inputURL = inputURL ?? URL(fileURLWithPath: "/dev/null")
        } else {
            guard let backend else {
                throw BenchmarkError.missingOption("--backend")
            }
            guard let inputURL else {
                throw BenchmarkError.missingOption("--input")
            }
            self.backend = backend
            self.inputURL = inputURL
        }
        self.outputURL = outputURL
        self.usesWarmup = usesWarmup && self.backend != .apple
        self.printsHelp = printsHelp
        self.postEditBackend = postEditBackend
        self.postEditContextLimit = postEditContextLimit
        self.translateGemmaPythonExecutable = pythonExecutable
        self.translateGemmaScriptURL = scriptURL
        self.translateGemmaModelID = modelID
    }

    private static func value(after option: String, in arguments: [String], at index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw BenchmarkError.missingValue(option)
        }
        index = valueIndex
        return arguments[valueIndex]
    }
}

private enum TranslationBackend: String {
    case apple
    case madlad
    case translateGemma = "translategemma"
}

private enum PostEditBackend: String {
    case none
    case glossary
    case appleFoundation = "apple-foundation"
}

private enum BenchmarkError: LocalizedError {
    case appleTranslationUnavailable
    case appleFoundationModelsUnavailable(String)
    case emptyPostEdit
    case invalidBackend(String)
    case invalidPostEditBackend(String)
    case invalidPostEditContext(String)
    case missingOption(String)
    case missingValue(String)
    case unknownArgument(String)

    var errorDescription: String? {
        switch self {
        case .appleTranslationUnavailable:
            "Apple Translation is unavailable in this toolchain."
        case .appleFoundationModelsUnavailable(let reason):
            "Apple Foundation Models post-edit is unavailable: \(reason)"
        case .emptyPostEdit:
            "The post-editor returned empty text."
        case .invalidBackend(let value):
            "Invalid backend \(value). Use apple, madlad, or translategemma."
        case .invalidPostEditBackend(let value):
            "Invalid post-edit backend \(value). Use none, glossary, or apple-foundation."
        case .invalidPostEditContext(let value):
            "Invalid post-edit context \(value). Use a value from 0 through 8."
        case .missingOption(let option):
            "Missing required option \(option)."
        case .missingValue(let option):
            "Missing value after \(option)."
        case .unknownArgument(let argument):
            "Unknown argument \(argument)."
        }
    }
}

private struct BenchmarkTranslationContextItem: Sendable {
    let sourceText: String
    let acceptedTranslation: String
}

private protocol TranslationPostEditor: Sendable {
    func prepare(targetLanguageCode: String) async throws
    func edit(
        sourceText: String,
        draftTranslation: String,
        sourceLanguageCode: String,
        targetLanguageCode: String,
        context: [BenchmarkTranslationContextItem]
    ) async throws -> String
}

private struct GlossaryBenchmarkPostEditor: TranslationPostEditor {
    private let postEditor = HeptapodTerminologyPostEditor.englishToTurkishLiveSpeech

    func prepare(targetLanguageCode: String) async throws {}

    func edit(
        sourceText: String,
        draftTranslation: String,
        sourceLanguageCode: String,
        targetLanguageCode: String,
        context: [BenchmarkTranslationContextItem]
    ) async throws -> String {
        try await postEditor.edit(
            HeptapodTranslatedText(
                sourceText: sourceText,
                translatedText: draftTranslation,
                sourceLanguageCode: sourceLanguageCode,
                targetLanguageCode: targetLanguageCode
            ),
            context: context.map {
                HeptapodTranslationContextItem(
                    sourceText: $0.sourceText,
                    acceptedTranslation: $0.acceptedTranslation
                )
            }
        )
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, *)
@Generable
private struct TurkishPostEditOutput {
    @Guide(description: "The final natural Turkish translation, with no notes or explanation.")
    let translation: String
}

@available(macOS 26.0, iOS 26.0, *)
private struct AppleFoundationModelsTurkishPostEditor: TranslationPostEditor {
    private let model = SystemLanguageModel.default

    func prepare(targetLanguageCode: String) async throws {
        guard targetLanguageCode.lowercased().hasPrefix("tr") else {
            throw BenchmarkError.appleFoundationModelsUnavailable(
                "This experiment currently supports Turkish output only."
            )
        }
        guard case .available = model.availability else {
            throw BenchmarkError.appleFoundationModelsUnavailable(String(describing: model.availability))
        }
        guard model.supportsLocale(Locale(identifier: "tr_TR")) else {
            throw BenchmarkError.appleFoundationModelsUnavailable("The system model does not support Turkish.")
        }
    }

    func edit(
        sourceText: String,
        draftTranslation: String,
        sourceLanguageCode: String,
        targetLanguageCode: String,
        context: [BenchmarkTranslationContextItem]
    ) async throws -> String {
        let session = LanguageModelSession(
            model: model,
            instructions: """
            You are a conservative translation post-editor for spoken Turkish.
            Improve only grammar, natural Turkish word order, and mistranslated technical terminology.
            Preserve every fact, name, number, condition, and degree of certainty from the source.
            Do not summarize, explain, add information, or omit information.
            Keep terminology consistent with the accepted context when context is present.
            """
        )
        let response = try await session.respond(
            to: prompt(
                sourceText: sourceText,
                draftTranslation: draftTranslation,
                sourceLanguageCode: sourceLanguageCode,
                targetLanguageCode: targetLanguageCode,
                context: context
            ),
            generating: TurkishPostEditOutput.self,
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 160)
        )
        let edited = response.content.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard edited.isEmpty == false else {
            throw BenchmarkError.emptyPostEdit
        }
        return edited
    }

    private func prompt(
        sourceText: String,
        draftTranslation: String,
        sourceLanguageCode: String,
        targetLanguageCode: String,
        context: [BenchmarkTranslationContextItem]
    ) -> String {
        let contextText: String
        if context.isEmpty {
            contextText = "None"
        } else {
            contextText = context.enumerated().map { index, item in
                """
                Pair \(index + 1) source: \(item.sourceText)
                Pair \(index + 1) accepted Turkish: \(item.acceptedTranslation)
                """
            }.joined(separator: "\n")
        }

        return """
        Source language: \(sourceLanguageCode)
        Target language: \(targetLanguageCode)

        Previous accepted sentence pairs:
        \(contextText)

        Current source:
        \(sourceText)

        Draft Turkish translation:
        \(draftTranslation)

        Return the corrected Turkish translation. If the draft is already accurate and natural, return it unchanged.
        """
    }
}
#endif
