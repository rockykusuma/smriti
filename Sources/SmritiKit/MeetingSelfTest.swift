import AVFoundation
import Foundation

/// A no-call check of the real meeting-capture path. It runs the exact same
/// ScreenCaptureKit dual-track recorder the menu bar uses (system audio + mic),
/// for a few seconds, then reports the duration, format, and peak level of each
/// track. This decouples "does the SCK mic path record real audio?" from
/// needing a live two-person call — the historical `me.caf` silence bug can be
/// reproduced (or cleared) just by talking for a few seconds.
///
/// Needs the installed / signed binary: it exercises Microphone and Screen
/// Recording, which abort or are denied on an unsigned `swift run` dev build.
public enum MeetingSelfTest {

    /// Record `seconds` of system + mic audio via the SCK recorder and print a
    /// per-track report. Returns true when the mic track captured real audio.
    @discardableResult
    public static func run(seconds: Double) -> Bool {
        guard MeetingWatcher.meetingFeaturesEnabled else {
            fputs("""
            smriti meeting-selftest: meeting features are disabled for this build \
            (unsigned dev build or SMRITI_NO_MEETINGS). Run the installed binary, \
            e.g. /usr/local/bin/smriti meeting-selftest, so Microphone and Screen \
            Recording work.\n
            """, stderr)
            return false
        }

        let recorder = MeetingRecorder()
        do {
            try recorder.start(appName: "SelfTest")
        } catch {
            fputs("smriti meeting-selftest: could not start capture: \(error)\n", stderr)
            return false
        }

        fputs("""
        smriti meeting-selftest: recording \(Int(seconds))s. SPEAK now to test the \
        mic track, and play some audio (music/video) to test the system track…\n
        """, stderr)
        // Keep the process alive and the main run loop pumping while SCK
        // delivers sample buffers on its own queue.
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))

        guard let recording = recorder.stop() else {
            fputs("smriti meeting-selftest: nothing recorded.\n", stderr)
            return false
        }
        // Give the async stream a beat to flush its final buffers/close files.
        Thread.sleep(forTimeInterval: 0.4)

        let system = analyze(recording.systemTrack)
        let mic = analyze(recording.micTrack)
        print("system (them.caf): \(system.summary)")
        print("mic    (me.caf):   \(mic.summary)")
        print("files: \(recording.directory.path)")

        if !mic.hasAudio {
            print("""
            → mic track is silent. Not a capture-path bug you can fix by talking \
            louder: check that Screen Recording AND Microphone are granted for \
            this binary, and that no virtual-audio device (whisper/dictation \
            tools) is the default input.
            """)
        }
        return mic.hasAudio
    }

    private struct Track {
        let summary: String
        let hasAudio: Bool
    }

    private static func analyze(_ url: URL) -> Track {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Track(summary: "NO FILE — nothing was captured on this track", hasAudio: false)
        }
        guard let file = try? AVAudioFile(forReading: url) else {
            return Track(summary: "file unreadable at \(url.lastPathComponent)", hasAudio: false)
        }
        let fmt = file.processingFormat
        let duration = fmt.sampleRate > 0 ? Double(file.length) / fmt.sampleRate : 0
        let peak = Double(peakLevel(file: file, format: fmt))
        let dbfs = peak > 0 ? String(format: "%.1f", 20 * log10(peak)) : "-inf"
        let hasAudio = peak >= 1e-3 // ~ -60 dBFS; below this is effectively silence
        let verdict = hasAudio ? "OK ✓" : (peak > 0 ? "very quiet ⚠︎" : "SILENT ✗")
        let summary = String(
            format: "%.1fs, %.0f Hz, %ld ch, peak %.4f (%@ dBFS) — %@",
            duration, fmt.sampleRate, Int(fmt.channelCount), peak, dbfs, verdict)
        return Track(summary: summary, hasAudio: hasAudio)
    }

    private static func peakLevel(file: AVAudioFile, format: AVAudioFormat) -> Float {
        let total = AVAudioFrameCount(file.length)
        guard total > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
              (try? file.read(into: buffer)) != nil,
              let channels = buffer.floatChannelData
        else { return 0 }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var peak: Float = 0
        if format.isInterleaved {
            let p = channels[0]
            for i in 0 ..< (frames * channelCount) { peak = max(peak, abs(p[i])) }
        } else {
            for c in 0 ..< channelCount {
                let p = channels[c]
                for i in 0 ..< frames { peak = max(peak, abs(p[i])) }
            }
        }
        return peak
    }
}
