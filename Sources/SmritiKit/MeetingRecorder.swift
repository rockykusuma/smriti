import AVFoundation
import Foundation
import ScreenCaptureKit

/// Records a meeting as two local tracks: system audio (the other
/// participants, via ScreenCaptureKit) and the microphone (the user).
/// Nothing leaves the Mac; files live under Application Support/Smriti.
final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

    struct Recording {
        let directory: URL
        let systemTrack: URL
        let micTrack: URL
        let startedAt: Date
        let appName: String
    }

    private var stream: SCStream?
    private let engine = AVAudioEngine()
    private var systemFile: AVAudioFile?
    private var micFile: AVAudioFile?
    private(set) var current: Recording?
    private let sampleQueue = DispatchQueue(label: "smriti.meeting.audio")

    var isRecording: Bool { current != nil }

    /// Start both tracks. Triggers Microphone and Screen Recording TCC
    /// prompts on first use.
    func start(appName: String) throws {
        guard current == nil else { return }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HHmm"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        let dir = Config.supportDirectory
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("\(stamp.string(from: Date()))_\(appName.replacingOccurrences(of: "/", with: "-"))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let recording = Recording(
            directory: dir,
            systemTrack: dir.appendingPathComponent("them.caf"),
            micTrack: dir.appendingPathComponent("me.caf"),
            startedAt: Date(),
            appName: appName)

        // Mic track (the user's side).
        let micFormat = engine.inputNode.outputFormat(forBus: 0)
        micFile = try AVAudioFile(forWriting: recording.micTrack, settings: micFormat.settings)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
            try? self?.micFile?.write(from: buffer)
        }
        try engine.start()

        // System-audio track (everyone else). Audio-only SCK stream.
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self else { return }
            guard let display = content?.displays.first else {
                fputs("smriti meeting: no display for system audio (\(error.map(String.init(describing:)) ?? "unknown"))\n", stderr)
                return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            // Keep video work negligible; SCK requires a video stream.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.sampleQueue)
                stream.startCapture { error in
                    if let error {
                        fputs("smriti meeting: system audio failed: \(error) (grant Screen Recording in System Settings)\n", stderr)
                    } else {
                        fputs("smriti meeting: system audio rolling\n", stderr)
                    }
                }
                self.stream = stream
            } catch {
                fputs("smriti meeting: stream setup failed: \(error)\n", stderr)
            }
        }

        current = recording
        fputs("smriti meeting: recording started (\(appName)) → \(dir.path)\n", stderr)
    }

    /// Stop and return the finished recording's metadata.
    func stop() -> Recording? {
        guard let recording = current else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        micFile = nil
        stream?.stopCapture { _ in }
        stream = nil
        systemFile = nil
        current = nil
        fputs("smriti meeting: recording stopped (\(Int(Date().timeIntervalSince(recording.startedAt)))s)\n", stderr)
        return recording
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, current != nil,
              sampleBuffer.isValid,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer)
        else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList)
        guard status == noErr else { return }

        do {
            if systemFile == nil, let recording = current {
                systemFile = try AVAudioFile(
                    forWriting: recording.systemTrack, settings: format.settings)
            }
            try systemFile?.write(from: pcm)
        } catch {
            fputs("smriti meeting: system track write failed: \(error)\n", stderr)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("smriti meeting: system audio stream stopped: \(error)\n", stderr)
    }
}
