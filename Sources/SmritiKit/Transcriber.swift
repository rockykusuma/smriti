import AVFoundation
import Foundation
import Speech

/// On-device transcription of recorded meeting tracks. Uses Apple's speech
/// engine with `requiresOnDeviceRecognition` — audio never leaves the Mac.
public enum Transcriber {

    public static func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { status in
            fputs("smriti transcribe: speech authorization = \(status.rawValue)\n", stderr)
        }
    }

    /// Convert any audio file to mono 16 kHz Int16 WAV — the recognizer's
    /// preferred shape. The speech engine returns "no speech detected" on
    /// multi-channel / float recordings, so we always normalize first.
    /// Returns a temp-file URL, or nil on failure.
    static func normalizedMono16k(_ src: URL) -> URL? {
        guard let inFile = try? AVAudioFile(forReading: src) else { return nil }
        let inFormat = inFile.processingFormat
        // Use the standard deinterleaved Float32 format — this is exactly the
        // processing format AVAudioFile expects for writes, so buffers pass
        // through without an internal (crash-prone) conversion.
        guard inFormat.sampleRate > 0,
              let outFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
              let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { return nil }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smriti-\(UUID().uuidString).caf")
        guard let outFile = try? AVAudioFile(forWriting: outURL, settings: outFormat.settings)
        else { return nil }

        let chunk: AVAudioFrameCount = 16384
        let ratio = outFormat.sampleRate / inFormat.sampleRate
        while true {
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk)
            else { break }
            do { try inFile.read(into: inBuf) } catch { break }
            if inBuf.frameLength == 0 { break }

            let cap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap)
            else { break }
            var supplied = false
            var err: NSError?
            let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
                if supplied { outStatus.pointee = .noDataNow; return nil }
                supplied = true
                outStatus.pointee = .haveData
                return inBuf
            }
            if status == .error { break }
            if outBuf.frameLength > 0 { try? outFile.write(from: outBuf) }
            if inBuf.frameLength < chunk { break }
        }
        return outURL
    }

    /// Transcribe one audio file on-device. Normalizes to mono 16 kHz, then
    /// recognizes in short chunks — Apple's on-device recognizer is reliable
    /// on short clips but stalls on long single files. Returns nil when
    /// recognition is unavailable or produced nothing.
    public static func transcribe(file: URL, locale: Locale = Locale(identifier: "en-US")) -> String? {
        guard FileManager.default.fileExists(atPath: file.path),
              let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable
        else { return nil }

        guard let normalized = normalizedMono16k(file),
              let inFile = try? AVAudioFile(forReading: normalized)
        else { return nil }
        defer { try? FileManager.default.removeItem(at: normalized) }

        let format = inFile.processingFormat
        let totalSeconds = format.sampleRate > 0 ? Double(inFile.length) / format.sampleRate : 0

        // Short recordings: one pass. Chunking a short clip risks cutting a
        // phrase at a seam (which loses it), and single-file recognition is
        // reliable at these lengths.
        if totalSeconds <= 55 {
            if let whole = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(max(inFile.length, 1))) {
                try? inFile.read(into: whole)
                if chunkPeak(whole) < 0.01 { return nil } // all silence
            }
            let text = recognizeClip(normalized, locale: locale)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty == false) ? text : nil
        }

        // Long recordings: overlapping ~40s chunks. Apple's on-device
        // recognizer stalls on long single files; the 4s overlap keeps speech
        // that lands on a chunk boundary intact in at least one chunk.
        let chunkFrames = AVAudioFrameCount(format.sampleRate * 40)
        let overlapFrames = Int64(format.sampleRate * 4)
        let hop = Int64(chunkFrames) - overlapFrames
        var pieces: [String] = []
        var index = 0
        var start: Int64 = 0

        while start < inFile.length {
            inFile.framePosition = start
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)
            else { break }
            do { try inFile.read(into: buffer, frameCount: chunkFrames) } catch { break }
            if buffer.frameLength == 0 { break }
            index += 1

            // Skip near-silent chunks: the recognizer would otherwise wait out
            // its full timeout on silence and return nothing.
            if chunkPeak(buffer) < 0.01 {
                fputs("smriti transcribe: \(file.lastPathComponent) chunk \(index) skipped (silent)\n", stderr)
                start += hop
                continue
            }

            let chunkURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("smriti-chunk-\(UUID().uuidString).caf")
            if let out = try? AVAudioFile(forWriting: chunkURL, settings: format.settings) {
                try? out.write(from: buffer)
            } // `out` is released here, flushing the file to disk before we read it.

            if let text = recognizeClip(chunkURL, locale: locale)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty, text != pieces.last {
                pieces.append(text)
            }
            try? FileManager.default.removeItem(at: chunkURL)
            fputs("smriti transcribe: \(file.lastPathComponent) chunk \(index) done (\(pieces.count) with speech)\n", stderr)

            start += hop
        }

        let joined = pieces.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    /// Peak absolute amplitude of a mono float buffer.
    private static func chunkPeak(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0] else { return 1 }
        var peak: Float = 0
        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(ch[i])) }
        return peak
    }

    /// Recognize a single short clip on-device (no normalization/chunking).
    private static func recognizeClip(_ url: URL, locale: Locale) -> String? {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable
        else { return nil }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        if #available(macOS 13.0, *) { request.addsPunctuation = true }

        var transcript: String?
        let semaphore = DispatchSemaphore(value: 0)
        recognizer.recognitionTask(with: request) { result, error in
            if error != nil { semaphore.signal(); return }
            guard let result else { return }
            if result.isFinal {
                transcript = result.bestTranscription.formattedString
                semaphore.signal()
            }
        }
        _ = semaphore.wait(timeout: .now() + 120)
        return transcript?.isEmpty == false ? transcript : nil
    }

    /// Transcribe the `them.caf` / `me.caf` tracks inside a meeting directory
    /// and merge them into a readable document.
    public static func transcript(inDirectory dir: URL) -> String {
        let them = transcribe(file: dir.appendingPathComponent("them.caf"))
        let me = transcribe(file: dir.appendingPathComponent("me.caf"))

        var parts: [String] = []
        if let them { parts.append("## Others said\n\n\(them)") }
        if let me { parts.append("## You said\n\n\(me)") }
        if parts.isEmpty {
            parts.append("(Transcription unavailable — audio kept at \(dir.path))")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Transcribe both tracks of a freshly finished recording.
    static func meetingTranscript(recording: MeetingRecorder.Recording) -> String {
        transcript(inDirectory: recording.directory)
    }
}
