import Foundation
import Speech

/// On-device transcription of recorded meeting tracks. Uses Apple's speech
/// engine with `requiresOnDeviceRecognition` — audio never leaves the Mac.
enum Transcriber {

    static func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { status in
            fputs("smriti transcribe: speech authorization = \(status.rawValue)\n", stderr)
        }
    }

    /// Transcribe one audio file. Returns nil when recognition is
    /// unavailable or produced nothing.
    static func transcribe(file: URL, locale: Locale = Locale(identifier: "en-US")) -> String? {
        guard FileManager.default.fileExists(atPath: file.path),
              let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable
        else { return nil }

        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        if #available(macOS 13.0, *) { request.addsPunctuation = true }

        var transcript: String?
        let semaphore = DispatchSemaphore(value: 0)
        recognizer.recognitionTask(with: request) { result, error in
            if let error {
                fputs("smriti transcribe: \(file.lastPathComponent): \(error.localizedDescription)\n", stderr)
                semaphore.signal()
                return
            }
            guard let result else { return }
            if result.isFinal {
                transcript = result.bestTranscription.formattedString
                semaphore.signal()
            }
        }
        // Long meetings take a while on-device; cap at 10 minutes.
        _ = semaphore.wait(timeout: .now() + 600)
        return transcript?.isEmpty == false ? transcript : nil
    }

    /// Transcribe both tracks and merge into a readable document.
    static func meetingTranscript(recording: MeetingRecorder.Recording) -> String {
        let them = transcribe(file: recording.systemTrack)
        let me = transcribe(file: recording.micTrack)

        var parts: [String] = []
        if let them { parts.append("## Others said\n\n\(them)") }
        if let me { parts.append("## You said\n\n\(me)") }
        if parts.isEmpty {
            parts.append("(Transcription unavailable — audio kept at \(recording.directory.path))")
        }
        return parts.joined(separator: "\n\n")
    }
}
