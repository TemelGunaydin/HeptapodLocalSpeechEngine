#if os(macOS)
import AudioCommon
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import HeptapodLocalSpeechEngine
import ScreenCaptureKit

public final class HeptapodScreenCaptureSystemAudioSource: HeptapodAudioChunkSource {
    public let targetSampleRate: Int
    public let captureSampleRate: Int
    public let channelCount: Int
    public let chunkDurationSeconds: Double
    public let maximumDurationSeconds: Double?
    public let excludesCurrentProcessAudio: Bool

    public init(
        targetSampleRate: Int = 16_000,
        captureSampleRate: Int = 48_000,
        channelCount: Int = 2,
        chunkDurationSeconds: Double = 1.0,
        maximumDurationSeconds: Double? = nil,
        excludesCurrentProcessAudio: Bool = true
    ) {
        self.targetSampleRate = targetSampleRate
        self.captureSampleRate = captureSampleRate
        self.channelCount = channelCount
        self.chunkDurationSeconds = chunkDurationSeconds
        self.maximumDurationSeconds = maximumDurationSeconds
        self.excludesCurrentProcessAudio = excludesCurrentProcessAudio
    }

    public func chunks() -> AsyncThrowingStream<HeptapodAudioChunk, Error> {
        let targetSampleRate = targetSampleRate
        let captureSampleRate = captureSampleRate
        let channelCount = channelCount
        let chunkSampleCount = max(1, Int(Double(targetSampleRate) * chunkDurationSeconds))
        let maximumSampleCount = maximumDurationSeconds.map { Int($0 * Double(targetSampleRate)) }
        let excludesCurrentProcessAudio = excludesCurrentProcessAudio

        return AsyncThrowingStream { continuation in
            let state = SystemAudioChunkState(
                continuation: continuation,
                targetSampleRate: targetSampleRate,
                chunkSampleCount: chunkSampleCount,
                maximumSampleCount: maximumSampleCount
            )
            let streamBox = SystemAudioStreamBox()

            let task = Task {
                do {
                    let content = try await SCShareableContent.current
                    guard let display = content.displays.first else {
                        throw HeptapodSystemAudioCaptureError.noDisplayAvailable
                    }

                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let configuration = SCStreamConfiguration()
                    configuration.width = 2
                    configuration.height = 2
                    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                    configuration.queueDepth = 3
                    configuration.showsCursor = false
                    configuration.capturesAudio = true
                    configuration.sampleRate = captureSampleRate
                    configuration.channelCount = channelCount
                    configuration.excludesCurrentProcessAudio = excludesCurrentProcessAudio

                    let output = SystemAudioStreamOutput(state: state)
                    let delegate = SystemAudioStreamDelegate(continuation: continuation)
                    let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
                    try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: streamBox.queue)
                    try await stream.startCapture()

                    await streamBox.set(stream: stream, output: output, delegate: delegate)
                } catch {
                    continuation.finish(throwing: HeptapodSystemAudioCaptureError.captureStartFailed(error))
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
                Task {
                    await streamBox.stop()
                }
            }
        }
    }
}
#endif

public enum HeptapodSystemAudioCaptureError: LocalizedError, Sendable {
    case noDisplayAvailable
    case captureStartFailed(Error)
    case audioFormatUnavailable
    case unsupportedAudioFormat(formatID: AudioFormatID, flags: AudioFormatFlags)
    case sampleBufferReadFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            "No display is available for ScreenCaptureKit system audio capture."
        case .captureStartFailed(let error):
            "Could not start system audio capture. Grant Screen Recording permission if macOS asks. Underlying error: \(error.localizedDescription)"
        case .audioFormatUnavailable:
            "ScreenCaptureKit did not provide an audio stream format."
        case .unsupportedAudioFormat(let formatID, let flags):
            "Unsupported ScreenCaptureKit audio format: formatID \(formatID), flags \(flags)."
        case .sampleBufferReadFailed(let status):
            "Could not read ScreenCaptureKit audio sample buffer. OSStatus: \(status)."
        }
    }
}

private actor SystemAudioStreamBox {
    let queue = DispatchQueue(label: "heptapod.system-audio-capture")
    private var stream: SCStream?
    private var output: SystemAudioStreamOutput?
    private var delegate: SystemAudioStreamDelegate?

    func set(stream: SCStream, output: SystemAudioStreamOutput, delegate: SystemAudioStreamDelegate) {
        self.stream = stream
        self.output = output
        self.delegate = delegate
    }

    func stop() async {
        guard let stream else {
            return
        }

        try? await stream.stopCapture()
        if let output {
            try? stream.removeStreamOutput(output, type: .audio)
        }
        self.stream = nil
        self.output = nil
        self.delegate = nil
    }
}

private final class SystemAudioStreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<HeptapodAudioChunk, Error>.Continuation

    init(continuation: AsyncThrowingStream<HeptapodAudioChunk, Error>.Continuation) {
        self.continuation = continuation
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        continuation.finish(throwing: error)
    }
}

private final class SystemAudioStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let state: SystemAudioChunkState

    init(state: SystemAudioChunkState) {
        self.state = state
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else {
            return
        }

        do {
            try state.consume(sampleBuffer: sampleBuffer)
        } catch {
            state.finish(throwing: error)
        }
    }
}

private final class SystemAudioChunkState: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<HeptapodAudioChunk, Error>.Continuation
    private let targetSampleRate: Int
    private let chunkSampleCount: Int
    private let maximumSampleCount: Int?
    private var samples: [Float] = []
    private var emittedSampleCount = 0
    private var isFinished = false

    init(
        continuation: AsyncThrowingStream<HeptapodAudioChunk, Error>.Continuation,
        targetSampleRate: Int,
        chunkSampleCount: Int,
        maximumSampleCount: Int?
    ) {
        self.continuation = continuation
        self.targetSampleRate = targetSampleRate
        self.chunkSampleCount = chunkSampleCount
        self.maximumSampleCount = maximumSampleCount
    }

    func consume(sampleBuffer: CMSampleBuffer) throws {
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else {
            return
        }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            throw HeptapodSystemAudioCaptureError.audioFormatUnavailable
        }

        let incoming = try Self.monoFloatSamples(from: sampleBuffer, streamDescription: streamDescription)
        let inputSampleRate = Int(streamDescription.mSampleRate)
        let resampled = inputSampleRate == targetSampleRate
            ? incoming
            : AudioFileLoader.resample(incoming, from: inputSampleRate, to: targetSampleRate)

        lock.lock()
        defer {
            lock.unlock()
        }

        guard isFinished == false else {
            return
        }

        samples.append(contentsOf: resampled)
        while samples.count >= chunkSampleCount {
            let chunkSamples = Array(samples.prefix(chunkSampleCount))
            samples.removeFirst(chunkSampleCount)
            emittedSampleCount += chunkSampleCount

            continuation.yield(
                HeptapodAudioChunk(
                    pcm16: HeptapodSpeechSwiftAudioSamples.pcm16Data(from: chunkSamples),
                    sampleRate: targetSampleRate
                )
            )

            if let maximumSampleCount, emittedSampleCount >= maximumSampleCount {
                isFinished = true
                continuation.finish()
                break
            }
        }
    }

    func finish(throwing error: Error) {
        lock.lock()
        let shouldFinish = isFinished == false
        isFinished = true
        lock.unlock()

        if shouldFinish {
            continuation.finish(throwing: error)
        }
    }

    private static func monoFloatSamples(
        from sampleBuffer: CMSampleBuffer,
        streamDescription: AudioStreamBasicDescription
    ) throws -> [Float] {
        var blockBuffer: CMBlockBuffer?
        var bufferListSize = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            throw HeptapodSystemAudioCaptureError.sampleBufferReadFailed(status)
        }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer {
            rawBuffer.deallocate()
        }

        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: rawBuffer.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            throw HeptapodSystemAudioCaptureError.sampleBufferReadFailed(status)
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(rawBuffer.assumingMemoryBound(to: AudioBufferList.self))
        let channelCount = max(1, Int(streamDescription.mChannelsPerFrame))
        let formatID = streamDescription.mFormatID
        let flags = streamDescription.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = flags & kAudioFormatFlagIsSignedInteger != 0
        let isNonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0

        guard formatID == kAudioFormatLinearPCM else {
            throw HeptapodSystemAudioCaptureError.unsupportedAudioFormat(formatID: formatID, flags: flags)
        }

        if isFloat, streamDescription.mBitsPerChannel == 32 {
            return readFloat32Samples(
                bufferList: bufferList,
                frameCount: CMSampleBufferGetNumSamples(sampleBuffer),
                channelCount: channelCount,
                isNonInterleaved: isNonInterleaved
            )
        }

        if isSignedInteger, streamDescription.mBitsPerChannel == 16 {
            return readInt16Samples(
                bufferList: bufferList,
                frameCount: CMSampleBufferGetNumSamples(sampleBuffer),
                channelCount: channelCount,
                isNonInterleaved: isNonInterleaved
            )
        }

        throw HeptapodSystemAudioCaptureError.unsupportedAudioFormat(formatID: formatID, flags: flags)
    }

    private static func readFloat32Samples(
        bufferList: UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        channelCount: Int,
        isNonInterleaved: Bool
    ) -> [Float] {
        var output = [Float]()
        output.reserveCapacity(frameCount)

        if isNonInterleaved, bufferList.count >= channelCount {
            let channels = bufferList.prefix(channelCount).compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }
            for frame in 0..<frameCount {
                output.append(average(channels.map { $0[frame] }))
            }
            return output
        }

        guard let data = bufferList.first?.mData?.assumingMemoryBound(to: Float.self) else {
            return []
        }
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += data[(frame * channelCount) + channel]
            }
            output.append(sum / Float(channelCount))
        }
        return output
    }

    private static func readInt16Samples(
        bufferList: UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        channelCount: Int,
        isNonInterleaved: Bool
    ) -> [Float] {
        var output = [Float]()
        output.reserveCapacity(frameCount)

        if isNonInterleaved, bufferList.count >= channelCount {
            let channels = bufferList.prefix(channelCount).compactMap { $0.mData?.assumingMemoryBound(to: Int16.self) }
            for frame in 0..<frameCount {
                output.append(average(channels.map { Float(Int16(littleEndian: $0[frame])) / 32768.0 }))
            }
            return output
        }

        guard let data = bufferList.first?.mData?.assumingMemoryBound(to: Int16.self) else {
            return []
        }
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += Float(Int16(littleEndian: data[(frame * channelCount) + channel])) / 32768.0
            }
            output.append(sum / Float(channelCount))
        }
        return output
    }

    private static func average(_ samples: [Float]) -> Float {
        guard samples.isEmpty == false else {
            return 0
        }
        return samples.reduce(0, +) / Float(samples.count)
    }
}
