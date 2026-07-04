import AVFoundation
import CoreAudio
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
    private var micConverter: AVAudioConverter?
    /// Mono 16 kHz in AVAudioFile's standard (deinterleaved Float32) format —
    /// small, recognizer-friendly, and matches the file's processing format so
    /// buffer writes don't hit a CoreAudio conversion assert.
    private let micTargetFormat = AVAudioFormat(
        standardFormatWithSampleRate: 16000, channels: 1)!
    private(set) var current: Recording?
    private let sampleQueue = DispatchQueue(label: "smriti.meeting.audio")
    /// Loudest sample seen on the mic track — used to detect a silent
    /// recording (e.g. the input device delivered no audio).
    private var micPeak: Float = 0

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

        // Make sure we actually hold Microphone access — a denied grant makes
        // AVAudioEngine deliver silent buffers rather than erroring.
        let micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
        if micAuth != .authorized {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                fputs("smriti meeting: microphone access \(granted ? "granted" : "DENIED — recording will be silent")\n", stderr)
            }
        }

        // Mic track (the user's side), normalized to mono 16 kHz. The raw
        // input node is frequently multi-channel float, which the on-device
        // recognizer reads as silence — so convert as we capture.
        micPeak = 0
        let micFormat = engine.inputNode.outputFormat(forBus: 0)
        fputs("smriti meeting: mic input device '\(MeetingRecorder.defaultInputDeviceName())' — \(micFormat.channelCount) ch, \(Int(micFormat.sampleRate)) Hz\n", stderr)
        micFile = try AVAudioFile(forWriting: recording.micTrack, settings: micTargetFormat.settings)
        micConverter = AVAudioConverter(from: micFormat, to: micTargetFormat)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
            self?.writeMic(buffer)
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
        micConverter = nil
        stream?.stopCapture { _ in }
        stream = nil
        systemFile = nil
        current = nil
        fputs("smriti meeting: recording stopped (\(Int(Date().timeIntervalSince(recording.startedAt)))s)\n", stderr)
        if micPeak < 1e-5 {
            fputs("smriti meeting: WARNING — mic track was silent (peak \(micPeak)); the input device delivered no audio. Check the mic input source and that no virtual audio device is the default input.\n", stderr)
        }
        return recording
    }

    /// Convert one captured mic buffer to mono 16 kHz and append it.
    private func writeMic(_ input: AVAudioPCMBuffer) {
        guard let converter = micConverter, let file = micFile else { return }
        let ratio = micTargetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(
            pcmFormat: micTargetFormat, frameCapacity: max(capacity, 1024)) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return }
        if let samples = output.floatChannelData?[0] {
            var peak: Float = 0
            for i in 0..<Int(output.frameLength) { peak = max(peak, abs(samples[i])) }
            if peak > micPeak { micPeak = peak }
        }
        try? file.write(from: output)
    }

    /// Name of the current default input device, for diagnostics.
    private static func defaultInputDeviceName() -> String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr
        else { return "unknown" }
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceNameCFString
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &nameSize, &name) == noErr,
              let cf = name?.takeRetainedValue()
        else { return "unknown" }
        return cf as String
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
