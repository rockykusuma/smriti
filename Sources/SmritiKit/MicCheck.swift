import AVFoundation
import Foundation

/// Quick microphone diagnostic: record a few seconds through the same
/// AVAudioEngine path meeting recording uses, and report the input device,
/// format, and captured signal level. Verifies capture without a real call.
public final class MicCheck {

    private var peak: Float = 0
    private var sumSquares: Double = 0
    private var sampleCount: Int = 0
    private var intervalPeak: Float = 0
    private let lock = NSLock()

    public init() {}

    /// Run the check and print a human-readable report. Returns true when
    /// audible signal was captured.
    @discardableResult
    public func run(seconds: Double = 3) -> Bool {
        // Ensure microphone access — a denied grant yields silent buffers.
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            let semaphore = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { _ in semaphore.signal() }
            _ = semaphore.wait(timeout: .now() + 20)
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            print("Mic check: microphone access DENIED. Grant it in System Settings > Privacy & Security > Microphone.")
            return false
        }

        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        let device = MeetingRecorder.defaultInputDeviceName()

        print("Mic check")
        print("  input device: \(device)")
        print("  format:       \(format.channelCount) ch, \(Int(format.sampleRate)) Hz")
        if format.channelCount != 1 {
            print("  note:         input is \(format.channelCount)-channel; meeting capture downmixes to mono.")
        }

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.accumulate(buffer)
        }

        do {
            try engine.start()
        } catch {
            print("  → could not start audio engine: \(error.localizedDescription)")
            return false
        }

        print("  recording \(Int(seconds))s… speak now.")
        // Print a level reading every 0.5s so you can see your voice register.
        let step = 0.5
        var elapsed = 0.0
        while elapsed < seconds {
            Thread.sleep(forTimeInterval: step)
            elapsed += step
            lock.lock()
            let ip = intervalPeak
            intervalPeak = 0
            lock.unlock()
            print(String(format: "    %4.1fs  %@  %@", elapsed, meterBar(Double(ip)), dbfs(Double(ip))))
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        let peakLevel = peak
        let rms = sampleCount > 0 ? sqrt(sumSquares / Double(sampleCount)) : 0
        let frames = sampleCount
        lock.unlock()

        print("  captured:     \(frames) samples")
        print("  peak:         \(dbfs(Double(peakLevel)))")
        print("  rms:          \(dbfs(rms))")

        // ~ -80 dBFS: effectively silence.
        if peakLevel < 1e-4 {
            print("  → SILENT. No audio was captured from this device.")
            print("    The engine bound to '\(device)'. If that isn't your real")
            print("    mic, change the input in System Settings > Sound > Input,")
            print("    or check that a virtual audio device isn't the default input.")
            return false
        }
        print("  → OK — audio captured. Meeting recording should work.")
        return true
    }

    private func accumulate(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var localPeak: Float = 0
        var localSq: Double = 0
        var localCount = 0
        if buffer.format.isInterleaved {
            let p = data[0]
            for i in 0..<(frames * channels) {
                let v = p[i]
                localPeak = max(localPeak, abs(v))
                localSq += Double(v) * Double(v)
            }
            localCount = frames * channels
        } else {
            for c in 0..<channels {
                let p = data[c]
                for i in 0..<frames {
                    let v = p[i]
                    localPeak = max(localPeak, abs(v))
                    localSq += Double(v) * Double(v)
                }
                localCount += frames
            }
        }
        lock.lock()
        peak = max(peak, localPeak)
        intervalPeak = max(intervalPeak, localPeak)
        sumSquares += localSq
        sampleCount += localCount
        lock.unlock()
    }

    /// A 20-wide bar from a linear level, scaled over -60..0 dBFS.
    private func meterBar(_ linear: Double) -> String {
        let db = linear > 0 ? 20 * log10(linear) : -100
        let filled = max(0, min(20, Int((db + 60) / 60 * 20)))
        return "[" + String(repeating: "█", count: filled)
            + String(repeating: "·", count: 20 - filled) + "]"
    }

    private func dbfs(_ linear: Double) -> String {
        guard linear > 0 else { return "-inf dBFS (silence)" }
        return String(format: "%.1f dBFS", 20 * log10(linear))
    }
}
