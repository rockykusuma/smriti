import AVFoundation
import CoreAudio
import Foundation
import ScreenCaptureKit

/// Records a meeting as two local tracks: system audio (the other
/// participants) and the microphone (the user) — both via ScreenCaptureKit.
///
/// The mic is captured through SCK (macOS 15+) rather than AVAudioEngine:
/// VoIP apps like WhatsApp hold the input device during a call, which starves
/// an AVAudioEngine tap (it records silence). SCK's microphone capture coexists
/// with the calling app. Nothing leaves the Mac; files live under
/// Application Support/Smriti.
final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

    struct Recording {
        let directory: URL
        let systemTrack: URL
        let micTrack: URL
        let startedAt: Date
        let appName: String
    }

    private var stream: SCStream?
    private var systemFile: AVAudioFile?
    private var micFile: AVAudioFile?
    /// Loudest sample seen on the mic track — to detect a silent recording.
    private var micPeak: Float = 0
    private(set) var current: Recording?
    private let sampleQueue = DispatchQueue(label: "smriti.meeting.audio")

    var isRecording: Bool { current != nil }

    /// Start both tracks. Triggers Microphone and Screen Recording TCC
    /// prompts on first use.
    func start(appName: String) throws {
        guard current == nil else { return }

        // Ensure Microphone access (SCK mic capture needs it too).
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                fputs("smriti meeting: microphone access \(granted ? "granted" : "DENIED")\n", stderr)
            }
        }

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

        micPeak = 0
        current = recording // set before the async callback so handlers write

        guard #available(macOS 15.0, *) else {
            fputs("smriti meeting: mic capture needs macOS 15+; recording system audio only\n", stderr)
            startStream(recording: recording, captureMic: false)
            fputs("smriti meeting: recording started (\(appName)) → \(dir.path)\n", stderr)
            return
        }
        fputs("smriti meeting: mic via ScreenCaptureKit ('\(MeetingRecorder.defaultInputDeviceName())')\n", stderr)
        startStream(recording: recording, captureMic: true)
        fputs("smriti meeting: recording started (\(appName)) → \(dir.path)\n", stderr)
    }

    private func startStream(recording: Recording, captureMic: Bool) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self else { return }
            guard let display = content?.displays.first else {
                fputs("smriti meeting: no display for capture (\(error.map(String.init(describing:)) ?? "unknown")) — grant Screen Recording\n", stderr)
                return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            if captureMic, #available(macOS 15.0, *) {
                config.captureMicrophone = true
            }
            // SCK requires a video stream; keep it negligible.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.sampleQueue)
                if captureMic, #available(macOS 15.0, *) {
                    try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: self.sampleQueue)
                }
                stream.startCapture { error in
                    if let error {
                        fputs("smriti meeting: capture failed: \(error) (grant Screen Recording in System Settings)\n", stderr)
                    } else {
                        fputs("smriti meeting: capture rolling\n", stderr)
                    }
                }
                self.stream = stream
            } catch {
                fputs("smriti meeting: stream setup failed: \(error)\n", stderr)
            }
        }
    }

    /// Stop and return the finished recording's metadata.
    func stop() -> Recording? {
        guard let recording = current else { return nil }
        stream?.stopCapture { _ in }
        stream = nil
        systemFile = nil
        micFile = nil
        current = nil
        fputs("smriti meeting: recording stopped (\(Int(Date().timeIntervalSince(recording.startedAt)))s)\n", stderr)
        if micPeak < 1e-5 {
            fputs("smriti meeting: WARNING — mic track was silent (peak \(micPeak)); the calling app may have blocked mic capture.\n", stderr)
        }
        return recording
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard current != nil, sampleBuffer.isValid,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer)
        else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)

        let isMic: Bool
        if #available(macOS 15.0, *) { isMic = (type == .microphone) } else { isMic = false }
        guard isMic || type == .audio else { return }

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
            if isMic {
                if micFile == nil, let recording = current {
                    micFile = try AVAudioFile(forWriting: recording.micTrack, settings: format.settings)
                }
                try micFile?.write(from: pcm)
                trackMicPeak(pcm)
            } else {
                if systemFile == nil, let recording = current {
                    systemFile = try AVAudioFile(forWriting: recording.systemTrack, settings: format.settings)
                }
                try systemFile?.write(from: pcm)
            }
        } catch {
            fputs("smriti meeting: track write failed: \(error)\n", stderr)
        }
    }

    private func trackMicPeak(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var peak: Float = 0
        if buffer.format.isInterleaved {
            let p = data[0]
            for i in 0..<(frames * channels) { peak = max(peak, abs(p[i])) }
        } else {
            for c in 0..<channels {
                let p = data[c]
                for i in 0..<frames { peak = max(peak, abs(p[i])) }
            }
        }
        if peak > micPeak { micPeak = peak }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("smriti meeting: stream stopped: \(error)\n", stderr)
    }

    /// Name of the current default input device, for diagnostics.
    static func defaultInputDeviceName() -> String {
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
}
