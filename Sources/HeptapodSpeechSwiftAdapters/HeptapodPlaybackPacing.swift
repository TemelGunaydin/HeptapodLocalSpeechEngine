import Foundation
import HeptapodLocalSpeechEngine

struct HeptapodPlaybackPacing: Sendable {
    let baseRate: Float
    let maximumRate: Float
    private(set) var rate: Float
    private(set) var isTrackingAudio = false
    private var segmentCount = 0
    private var pendingDuration: TimeInterval = 0
    private var peakPendingDuration: TimeInterval = 0
    private var completedDuration: TimeInterval = 0
    private var peakRate: Float
    private var lastUpdate: TimeInterval?

    init(baseRate: Float = 1, maximumRate: Float = 1.15) {
        let base = baseRate.isFinite ? min(max(baseRate, 0.5), 2) : 1
        self.baseRate = base
        self.maximumRate = maximumRate.isFinite ? min(max(maximumRate, base), 2) : base
        rate = base
        peakRate = base
    }

    var state: HeptapodPlaybackAudioState {
        HeptapodPlaybackAudioState(
            pendingAudioDuration: pendingDuration,
            peakPendingAudioDuration: peakPendingDuration,
            completedAudioDuration: completedDuration,
            playbackRate: rate,
            peakPlaybackRate: peakRate
        )
    }

    mutating func setBacklog(_ count: Int, at time: TimeInterval) {
        segmentCount = max(0, count)
        update(at: time)
    }

    mutating func enqueueAudio(duration: TimeInterval, at time: TimeInterval) {
        guard duration.isFinite, duration > 0 else { return }
        isTrackingAudio = true
        pendingDuration += duration
        peakPendingDuration = max(peakPendingDuration, pendingDuration)
        update(at: time)
    }

    mutating func completeAudio(duration: TimeInterval, at time: TimeInterval) {
        guard duration.isFinite, duration > 0 else { return }
        if isTrackingAudio {
            pendingDuration = max(0, pendingDuration - duration)
            if pendingDuration < 0.000_001 { pendingDuration = 0 }
            completedDuration += duration
        }
        update(at: time)
    }

    mutating func reset() {
        self = Self(baseRate: baseRate, maximumRate: maximumRate)
    }

    private mutating func update(at time: TimeInterval) {
        guard time.isFinite else { return }
        let elapsed = min(1, max(0, time - (lastUpdate ?? time)))
        lastUpdate = max(lastUpdate ?? time, time)

        let increase: Float
        if isTrackingAudio {
            // Keep two seconds of headroom. Recover excess PCM over a gentle
            // twenty-second horizon, rather than treating every segment alike.
            increase = Float(max(0, pendingDuration - 2) / 20)
        } else {
            increase = Float(min(3, max(0, segmentCount - 1))) * 0.05
        }
        let target = min(maximumRate, baseRate + increase)
        if segmentCount == 0, pendingDuration == 0 {
            rate = baseRate
        } else {
            // Limit rate changes by wall time, not by TTS chunk count.
            let step = Float(elapsed) * (target > rate ? 0.05 : 0.10)
            rate += min(step, max(-step, target - rate))
        }
        peakRate = max(peakRate, rate)
    }
}
