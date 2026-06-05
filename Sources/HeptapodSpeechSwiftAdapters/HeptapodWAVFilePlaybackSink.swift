import Foundation
import HeptapodLocalSpeechEngine

public actor HeptapodWAVFilePlaybackSink: HeptapodSpeechPlaybackSink {
    private let outputDirectory: URL
    private let filePrefix: String
    private var nextIndex = 1
    private var writtenURLs: [URL] = []

    public init(outputDirectory: URL, filePrefix: String = "segment") {
        self.outputDirectory = outputDirectory
        self.filePrefix = filePrefix
    }

    public func play(_ speech: HeptapodSynthesizedSpeech) async throws {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let filename = "\(filePrefix)-\(String(format: "%03d", nextIndex)).wav"
        nextIndex += 1
        let outputURL = outputDirectory.appendingPathComponent(filename)
        try HeptapodSpeechSwiftAudioIO.writeWAV(speech, to: outputURL)
        writtenURLs.append(outputURL)
    }

    public func writtenFiles() -> [URL] {
        writtenURLs
    }
}
