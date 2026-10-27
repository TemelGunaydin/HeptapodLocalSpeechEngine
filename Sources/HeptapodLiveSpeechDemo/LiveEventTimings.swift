import Foundation
import HeptapodLocalSpeechEngine

struct LiveEventTiming {
    var outputID: Int?
    var resultLatencySeconds: TimeInterval?
    var outputLatencySeconds: TimeInterval?
    var firstAudioLatencySeconds: TimeInterval?
    var playbackLatencySeconds: TimeInterval?
    var playbackDurationSeconds: TimeInterval?
    var stageDurationSeconds: TimeInterval?
    var queueWaitSeconds: TimeInterval?
}

/// Capture indices identify input chunks, which may produce multiple outputs.
/// Each serial stage consumes the next occurrence of that index independently.
struct LiveEventTimings {
    private struct Output {
        let id: Int
        let captureStartedAt: TimeInterval?
        let acceptedAt: TimeInterval
        var translationStartedAt: TimeInterval?
        var translationCompletedAt: TimeInterval?
        var synthesisStartedAt: TimeInterval?
        var firstAudioAt: TimeInterval?
        var resultAt: TimeInterval?
        var playbackQueuedAt: TimeInterval?
        var playbackStartedAt: TimeInterval?
        var playbackCompletedAt: TimeInterval?
    }

    private var currentCapture: (index: Int, startedAt: TimeInterval)?
    private var nextOutputID = 1
    private var outputs: [Int: [Output]] = [:]

    var pendingOutputCount: Int { outputs.values.reduce(0) { $0 + $1.count } }

    mutating func record(
        _ event: HeptapodLiveSpeechEvent,
        at now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> LiveEventTiming {
        switch event {
        case .segmentStarted(let index):
            currentCapture = (index, now)
        case .partialTranscript(let index, _), .transcript(let index, _):
            return LiveEventTiming(resultLatencySeconds: captureStart(for: index).map { now - $0 })
        case .outputQueued(let index, _):
            let output = Output(id: nextOutputID, captureStartedAt: captureStart(for: index), acceptedAt: now)
            nextOutputID += 1
            outputs[index, default: []].append(output)
            return LiveEventTiming(outputID: output.id)
        case .translationStarted(let index):
            return update(index, at: now, matching: { $0.translationStartedAt == nil }) { output, timing in
                timing.queueWaitSeconds = now - output.acceptedAt
                output.translationStartedAt = now
            }
        case .translationCompleted(let index):
            return update(index, at: now, matching: {
                $0.translationStartedAt != nil && $0.translationCompletedAt == nil
            }) { output, timing in
                timing.stageDurationSeconds = output.translationStartedAt.map { now - $0 }
                output.translationCompletedAt = now
            }
        case .synthesisStarted(let index):
            return update(index, at: now, matching: {
                $0.translationCompletedAt != nil && $0.synthesisStartedAt == nil
            }) { output, timing in
                timing.queueWaitSeconds = output.translationCompletedAt.map { now - $0 }
                output.synthesisStartedAt = now
            }
        case .synthesisAudioReady(let index):
            return update(index, at: now, matching: {
                $0.synthesisStartedAt != nil && $0.firstAudioAt == nil
            }) { output, timing in
                timing.firstAudioLatencySeconds = now - output.acceptedAt
                timing.stageDurationSeconds = output.synthesisStartedAt.map { now - $0 }
                output.firstAudioAt = now
            }
        case .result(let index, _):
            return update(index, at: now, matching: {
                $0.synthesisStartedAt != nil && $0.resultAt == nil
            }) { output, timing in
                timing.stageDurationSeconds = output.synthesisStartedAt.map { now - $0 }
                output.resultAt = now
            }
        case .translation(let index, _):
            return update(index, at: now, matching: {
                $0.translationCompletedAt != nil && $0.resultAt == nil
            }) { output, _ in
                output.resultAt = now
            }
        case .playbackQueued(let index, _):
            return update(index, at: now, matching: {
                $0.synthesisStartedAt != nil && $0.playbackQueuedAt == nil
            }) { output, _ in
                output.playbackQueuedAt = now
            }
        case .playbackStarted(let index):
            return update(index, at: now, matching: {
                $0.playbackQueuedAt != nil && $0.playbackStartedAt == nil
            }) { output, timing in
                timing.playbackLatencySeconds = output.resultAt.map { now - $0 }
                timing.queueWaitSeconds = (output.firstAudioAt ?? output.playbackQueuedAt).map { now - $0 }
                output.playbackStartedAt = now
            }
        case .playbackCompleted(let index):
            return update(index, at: now, matching: {
                $0.playbackStartedAt != nil && $0.playbackCompletedAt == nil
            }) { output, timing in
                timing.playbackLatencySeconds = output.resultAt.map { now - $0 }
                timing.playbackDurationSeconds = output.playbackStartedAt.map { now - $0 }
                output.playbackCompletedAt = now
            }
        case .audioLevel, .silenceSkipped:
            break
        }
        return LiveEventTiming()
    }

    private func captureStart(for index: Int) -> TimeInterval? {
        currentCapture?.index == index ? currentCapture?.startedAt : nil
    }

    private mutating func update(
        _ index: Int,
        at now: TimeInterval,
        matching predicate: (Output) -> Bool,
        body: (inout Output, inout LiveEventTiming) -> Void
    ) -> LiveEventTiming {
        guard var occurrences = outputs[index], let position = occurrences.firstIndex(where: predicate) else {
            return LiveEventTiming()
        }
        var output = occurrences[position]
        var timing = LiveEventTiming(
            outputID: output.id,
            resultLatencySeconds: output.captureStartedAt.map { now - $0 },
            outputLatencySeconds: now - output.acceptedAt
        )
        body(&output, &timing)

        // Streaming playback may finish before the result event is delivered.
        // Retain its timing until both sides finish, then release the occurrence.
        if output.resultAt != nil && (output.playbackQueuedAt == nil || output.playbackCompletedAt != nil) {
            occurrences.remove(at: position)
        } else {
            occurrences[position] = output
        }
        outputs[index] = occurrences.isEmpty ? nil : occurrences
        return timing
    }
}
