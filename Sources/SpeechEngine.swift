import Foundation
import AVFoundation

enum WisprError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

// One actor owns the Whisper context. No two inference calls use it concurrently.
actor SpeechEngine {
    private var context: UnsafeMutableRawPointer?

    func load(modelURL: URL) throws {
        guard context == nil else { return }
        guard FileManager.default.fileExists(atPath: modelURL.path),
              let loaded = wispr_whisper_create(modelURL.path) else {
            throw WisprError.message("The local speech model could not be loaded. Rebuild the app with scripts/build.sh.")
        }
        context = loaded
    }

    deinit { if let context { wispr_whisper_destroy(context) } }

    func transcribe(_ samples: [Float], language: String) throws -> String {
        try recognize(samples, language: language, wordTimings: false).text
    }

    func recognize(_ samples: [Float], language: String, wordTimings: Bool) throws -> RecognizedSpeech {
        guard let context else { throw WisprError.message("The speech model is still loading.") }
        guard samples.count >= 6_400 else { throw WisprError.message("That recording was too short. Hold Fn while you speak.") }
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
        guard rms > 0.0004 else { throw WisprError.message("No speech was detected. Check your microphone and try again.") }
        // Whisper works best with a little trailing silence and at least one second of audio.
        var padded = samples
        padded.append(contentsOf: repeatElement(0, count: max(4_000, 16_000 - samples.count)))
        var code: Int32 = 0
        let text = padded.withUnsafeBufferPointer { buffer in
            wispr_whisper_transcribe(context, buffer.baseAddress, Int32(buffer.count), language,
                                     Int32(min(6, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))),
                                     wordTimings ? 1 : 0, &code)
        }
        guard code == 0, let text else { throw WisprError.message("Speech recognition failed. Please try again.") }
        defer { wispr_string_free(text) }
        let result = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw WisprError.message("No speech was detected. Try speaking closer to the microphone.") }
        var words: [TimedSpeechWord] = []
        if wordTimings {
            for index in 0..<wispr_whisper_segment_count(context) {
                guard let segment = wispr_whisper_segment_text(context, index) else { continue }
                words.append(TimedSpeechWord(text: String(cString: segment),
                                             start: Double(wispr_whisper_segment_start(context, index)) / 100,
                                             end: Double(wispr_whisper_segment_end(context, index)) / 100))
            }
        }
        return RecognizedSpeech(text: result, words: words)
    }

    // Analysis stays off the main actor, alongside recognition. Audio is not retained in the draft.
    func prepare(_ samples: [Float], language: String, experimentalFormatting: Bool) throws -> DictationDraft {
        let speech = try recognize(samples, language: language, wordTimings: experimentalFormatting)
        return DictationFormatting.prepare(speech, samples: samples, enabled: experimentalFormatting)
    }
}

// Audio only lives in memory. No recordings or transcripts are written to disk.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var captureError: String?
    private var hasTap = false
    var onMeter: ((Float) -> Void)?

    func start() throws {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        captureError = nil
        lock.unlock()
        let input = engine.inputNode
        let sourceFormat = input.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0,
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                               channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw WisprError.message("No microphone is available. Choose an input in System Settings → Sound.")
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: sourceFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / sourceFormat.sampleRate) + 64)
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                if supplied { inputStatus.pointee = .noDataNow; return nil }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, let channel = converted.floatChannelData?[0] else {
                self.lock.lock()
                self.captureError = conversionError?.localizedDescription ?? "Audio conversion failed."
                self.lock.unlock()
                return
            }
            let count = Int(converted.frameLength)
            guard count > 0 else { return }
            self.lock.lock()
            let remaining = max(0, 16_000 * 120 - self.samples.count)
            self.samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: min(remaining, count)))
            self.lock.unlock()
            let rms = sqrt((0..<count).reduce(Float(0)) { $0 + channel[$1] * channel[$1] } / Float(count))
            self.onMeter?(min(1, max(0, (20 * log10(max(rms, 0.00001)) + 55) / 45)))
        }
        hasTap = true
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            hasTap = false
            throw error
        }
    }

    func stop() throws -> [Float] {
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        lock.lock()
        defer { lock.unlock() }
        if let captureError { throw WisprError.message(captureError) }
        let result = samples
        samples.removeAll(keepingCapacity: false)
        return result
    }

    static func readAudio(at url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length < 16_000 * 600,
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 64) else {
            throw WisprError.message("The audio file could not be opened.")
        }
        try file.read(into: source)
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return source
        }
        if let error { throw error }
        guard let channel = output.floatChannelData?[0] else { throw WisprError.message("The audio file is empty.") }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
