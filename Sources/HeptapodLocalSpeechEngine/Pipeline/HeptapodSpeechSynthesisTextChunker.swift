import Foundation
import NaturalLanguage

enum HeptapodSpeechSynthesisTextChunker {
    private struct Chunk {
        let range: Range<String.Index>
        let wordCount: Int
    }

    static func chunks(
        in text: String,
        maximumWordsPerChunk: Int = 18,
        minimumWordsPerChunk: Int = 4
    ) -> [String] {
        let trimmedTextRange = trimmedRange(in: text, range: text.startIndex..<text.endIndex)
        guard trimmedTextRange.isEmpty == false else {
            return []
        }

        let maximumWordsPerChunk = max(1, maximumWordsPerChunk)
        let minimumWordsPerChunk = min(
            max(1, minimumWordsPerChunk),
            maximumWordsPerChunk
        )
        let naturalChunks = sentenceRanges(in: text, range: trimmedTextRange).flatMap { sentenceRange in
            splitLongSentence(
                in: text,
                range: sentenceRange,
                maximumWordsPerChunk: maximumWordsPerChunk
            )
        }
        let mergedChunks = mergeShortChunks(
            naturalChunks,
            maximumWordsPerChunk: maximumWordsPerChunk,
            minimumWordsPerChunk: minimumWordsPerChunk
        )

        return mergedChunks.map { chunk in
            String(text[chunk.range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func sentenceRanges(
        in text: String,
        range: Range<String.Index>
    ) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: range) { tokenRange, _ in
            let trimmed = trimmedRange(in: text, range: tokenRange)
            if trimmed.isEmpty == false {
                ranges.append(trimmed)
            }
            return true
        }
        return ranges.isEmpty ? [trimmedRange(in: text, range: range)] : ranges
    }

    private static func splitLongSentence(
        in text: String,
        range: Range<String.Index>,
        maximumWordsPerChunk: Int
    ) -> [Chunk] {
        let words = wordRanges(in: text, range: range)
        guard words.count > maximumWordsPerChunk else {
            return [Chunk(range: range, wordCount: words.count)]
        }

        var chunks: [Chunk] = []
        var startWordIndex = 0
        while startWordIndex < words.count {
            let maximumEndIndex = min(startWordIndex + maximumWordsPerChunk, words.count)
            var endWordIndex = maximumEndIndex

            // Prefer a clause boundary inside the maximum-sized window. If a
            // clause itself is longer than the limit, the hard word boundary
            // below is still used instead of returning an oversized chunk.
            if maximumEndIndex < words.count {
                for candidateEndIndex in stride(
                    from: maximumEndIndex,
                    through: startWordIndex + 1,
                    by: -1
                ) {
                    let gap = words[candidateEndIndex - 1].upperBound..<words[candidateEndIndex].lowerBound
                    if text[gap].contains(where: { character in
                        character == "," || character == ";" || character == ":"
                    }) {
                        endWordIndex = candidateEndIndex
                        break
                    }
                }
            }

            let chunkStart = words[startWordIndex].lowerBound
            let chunkEnd = endWordIndex < words.count
                ? words[endWordIndex].lowerBound
                : range.upperBound
            let chunkRange = trimmedRange(in: text, range: chunkStart..<chunkEnd)
            chunks.append(Chunk(
                range: chunkRange,
                wordCount: endWordIndex - startWordIndex
            ))
            startWordIndex = endWordIndex
        }
        return chunks
    }

    private static func mergeShortChunks(
        _ chunks: [Chunk],
        maximumWordsPerChunk: Int,
        minimumWordsPerChunk: Int
    ) -> [Chunk] {
        var merged: [Chunk] = []
        var pending: Chunk?

        for chunk in chunks {
            if chunk.wordCount < minimumWordsPerChunk {
                if let current = pending {
                    if current.wordCount + chunk.wordCount <= maximumWordsPerChunk {
                        pending = merge(current, chunk)
                    } else {
                        merged.append(current)
                        pending = chunk
                    }
                } else {
                    pending = chunk
                }
                continue
            }

            if let current = pending {
                if let last = merged.last,
                   last.wordCount + current.wordCount <= maximumWordsPerChunk {
                    merged[merged.count - 1] = merge(last, current)
                } else if current.wordCount + chunk.wordCount <= maximumWordsPerChunk {
                    merged.append(merge(current, chunk))
                    pending = nil
                    continue
                } else {
                    merged.append(current)
                }
                pending = nil
            }
            merged.append(chunk)
        }

        if let current = pending {
            if let last = merged.last,
               last.wordCount + current.wordCount <= maximumWordsPerChunk {
                merged[merged.count - 1] = merge(last, current)
            } else {
                merged.append(current)
            }
        }

        return merged
    }

    private static func merge(_ lhs: Chunk, _ rhs: Chunk) -> Chunk {
        Chunk(
            range: lhs.range.lowerBound..<rhs.range.upperBound,
            wordCount: lhs.wordCount + rhs.wordCount
        )
    }

    private static func wordRanges(
        in text: String,
        range: Range<String.Index>
    ) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: range) { tokenRange, _ in
            ranges.append(tokenRange)
            return true
        }
        return ranges
    }

    private static func trimmedRange(
        in text: String,
        range: Range<String.Index>
    ) -> Range<String.Index> {
        var lowerBound = range.lowerBound
        var upperBound = range.upperBound

        while lowerBound < upperBound, text[lowerBound].isWhitespace {
            lowerBound = text.index(after: lowerBound)
        }
        while upperBound > lowerBound {
            let previous = text.index(before: upperBound)
            guard text[previous].isWhitespace else {
                break
            }
            upperBound = previous
        }
        return lowerBound..<upperBound
    }
}
