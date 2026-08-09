import Foundation
import NaturalLanguage

enum HeptapodSpeechSynthesisTextChunker {
    static func chunks(
        in text: String,
        maximumWordsPerChunk: Int = 18,
        minimumWordsPerChunk: Int = 4
    ) -> [String] {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else {
            return []
        }

        let maximumWordsPerChunk = max(1, maximumWordsPerChunk)
        let minimumWordsPerChunk = min(
            max(1, minimumWordsPerChunk),
            maximumWordsPerChunk
        )
        let naturalChunks = sentences(in: trimmedText).flatMap { sentence in
            splitLongSentence(
                sentence,
                maximumWordsPerChunk: maximumWordsPerChunk
            )
        }

        return mergeShortChunks(
            naturalChunks,
            maximumWordsPerChunk: maximumWordsPerChunk,
            minimumWordsPerChunk: minimumWordsPerChunk
        )
    }

    private static func sentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.isEmpty == false {
                sentences.append(sentence)
            }
            return true
        }
        return sentences.isEmpty ? [text] : sentences
    }

    private static func splitLongSentence(
        _ sentence: String,
        maximumWordsPerChunk: Int
    ) -> [String] {
        guard wordCount(in: sentence) > maximumWordsPerChunk else {
            return [sentence]
        }

        let clauses = clauses(in: sentence)
        guard clauses.count > 1 else {
            return [sentence]
        }

        var chunks: [String] = []
        var pending = ""
        for clause in clauses {
            let candidate = joined(pending, clause)
            if pending.isEmpty || wordCount(in: candidate) <= maximumWordsPerChunk {
                pending = candidate
            } else {
                chunks.append(pending)
                pending = clause
            }
        }
        if pending.isEmpty == false {
            chunks.append(pending)
        }
        return chunks
    }

    private static func clauses(in sentence: String) -> [String] {
        let terminators: Set<Character> = [",", ";", ":"]
        var clauses: [String] = []
        var clauseStart = sentence.startIndex

        for index in sentence.indices where terminators.contains(sentence[index]) {
            let clauseEnd = sentence.index(after: index)
            let clause = String(sentence[clauseStart..<clauseEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if clause.isEmpty == false {
                clauses.append(clause)
            }
            clauseStart = clauseEnd
        }

        if clauseStart < sentence.endIndex {
            let clause = String(sentence[clauseStart..<sentence.endIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if clause.isEmpty == false {
                clauses.append(clause)
            }
        }
        return clauses
    }

    private static func mergeShortChunks(
        _ chunks: [String],
        maximumWordsPerChunk: Int,
        minimumWordsPerChunk: Int
    ) -> [String] {
        var merged: [String] = []
        var pending = ""

        for chunk in chunks {
            guard wordCount(in: chunk) < minimumWordsPerChunk else {
                if pending.isEmpty == false {
                    let candidate = joined(pending, chunk)
                    if wordCount(in: candidate) <= maximumWordsPerChunk {
                        merged.append(candidate)
                    } else {
                        merged.append(pending)
                        merged.append(chunk)
                    }
                    pending = ""
                } else {
                    merged.append(chunk)
                }
                continue
            }

            if let last = merged.last {
                let candidate = joined(last, chunk)
                if wordCount(in: candidate) <= maximumWordsPerChunk {
                    merged[merged.count - 1] = candidate
                    continue
                }
            }
            pending = joined(pending, chunk)
        }

        if pending.isEmpty == false {
            if merged.isEmpty {
                merged.append(pending)
            } else {
                merged[merged.count - 1] = joined(merged[merged.count - 1], pending)
            }
        }
        return merged
    }

    private static func wordCount(in text: String) -> Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in
            count += 1
            return true
        }
        return count
    }

    private static func joined(_ lhs: String, _ rhs: String) -> String {
        if lhs.isEmpty {
            return rhs
        }
        if rhs.isEmpty {
            return lhs
        }
        return "\(lhs) \(rhs)"
    }
}
