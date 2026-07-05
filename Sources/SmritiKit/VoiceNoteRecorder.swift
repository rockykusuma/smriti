import AVFoundation
import Foundation

/// A lightweight, mic-only recorder for manual voice notes — you press record,
/// talk, press stop, and it's transcribed on-device and saved like a meeting.
///
/// Unlike `MeetingRecorder` (ScreenCaptureKit dual-track, for live calls), this
/// captures only the microphone through an `AVAudioEngine` tap. During a manual
/// note nothing else is holding the input device, so the plain engine tap is
/// reliable — and it needs only Microphone permission, not Screen Recording.
/// Files land under Application Support/Smriti/meetings so they flow through the
/// same transcription/storage path; nothing leaves the Mac.
public final class VoiceNoteRecorder {

    public struct Result {
        public let directory: URL
        public let startedAt: Date
        /// True when the whole recording was effectively silent (bad mic/device).
        public let silent: Bool
    }

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var directory: URL?
    private var startedAt = Date()
    private var peak: Float = 0
    private let lock = NSLock()

    public private(set) var isRecording = false

    public init() {}

    /// Begin recording the microphone to `me.caf`. Triggers the Microphone TCC
    /// prompt on first use. Throws if there's no usable input device.
    public func start() throws {
        guard !isRecording else { return }

        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                fputs("smriti voice-note: microphone access \(granted ? "granted" : "DENIED")\n", stderr)
            }
        }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HHmm"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        let dir = Config.supportDirectory
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("\(stamp.string(from: Date()))_VoiceNote", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("me.caf")

        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw NSError(domain: "smriti.voicenote", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no usable microphone input device"])
        }
        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)

        peak = 0
        file = audioFile
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            try? self.file?.write(from: buffer)
            self.track(buffer)
        }
        try engine.start()

        directory = dir
        startedAt = Date()
        isRecording = true
        fputs("smriti voice-note: recording (\(Int(format.sampleRate)) Hz, \(format.channelCount) ch) → \(url.path)\n", stderr)
    }

    /// Stop recording and return where the audio landed. The caller transcribes
    /// and stores it (kept off this class so it stays dependency-free).
    public func stop() -> Result? {
        guard isRecording, let dir = directory else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil // release → flush/close the file
        isRecording = false

        lock.lock(); let capturedPeak = peak; lock.unlock()
        let silent = capturedPeak < 1e-4
        fputs("smriti voice-note: stopped\(silent ? " — WARNING: captured audio was silent (check the mic/default input)" : "")\n", stderr)
        return Result(directory: dir, startedAt: startedAt, silent: silent)
    }

    private func track(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var localPeak: Float = 0
        if buffer.format.isInterleaved {
            let p = data[0]
            for i in 0 ..< (frames * channels) { localPeak = max(localPeak, abs(p[i])) }
        } else {
            for c in 0 ..< channels {
                let p = data[c]
                for i in 0 ..< frames { localPeak = max(localPeak, abs(p[i])) }
            }
        }
        lock.lock(); peak = max(peak, localPeak); lock.unlock()
    }
}
