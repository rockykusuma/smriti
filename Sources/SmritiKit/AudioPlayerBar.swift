import AppKit
import AVFoundation

/// Playback bar for a meeting's saved audio. Merges the saved tracks
/// (them.caf + me.caf, or just me.caf for voice notes) into one
/// AVMutableComposition so both sides play together, the way the call
/// sounded. Calls `onUnavailable` when the directory holds nothing playable.
final class AudioPlayerBar: NSView {

    /// Fired on the main thread when no playable audio was found — the owner
    /// should hide the bar. No error dialogs.
    var onUnavailable: (() -> Void)?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var desiredRate: Float = 1.0
    private var durationSeconds: Double = 0

    private let playButton = NSButton()
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1,
                                  target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private let rateButton = NSButton()

    init(directory: URL) {
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 32))
        buildControls()
        setEnabled(false)
        Task { await load(directory) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { stop() }

    /// Pause and release the player (called when the selected row changes or
    /// the user leaves the Meetings section).
    func stop() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        playButton.title = "▶"
    }

    // MARK: - Controls

    private func buildControls() {
        playButton.title = "▶"
        playButton.bezelStyle = .texturedRounded
        playButton.target = self
        playButton.action = #selector(togglePlay)

        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.isContinuous = true

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor

        rateButton.title = "1×"
        rateButton.bezelStyle = .texturedRounded
        rateButton.target = self
        rateButton.action = #selector(cycleRate)

        let stack = NSStackView(views: [playButton, slider, timeLabel, rateButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.frame = bounds
        stack.autoresizingMask = [.width, .height]
        addSubview(stack)
    }

    private func setEnabled(_ enabled: Bool) {
        playButton.isEnabled = enabled
        slider.isEnabled = enabled
        rateButton.isEnabled = enabled
    }

    // MARK: - Loading

    private func load(_ directory: URL) async {
        let candidates = ["them.caf", "me.caf"]
            .map { directory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let composition = AVMutableComposition()
        for url in candidates {
            let asset = AVURLAsset(url: url)
            guard let tracks = try? await asset.load(.tracks),
                  let duration = try? await asset.load(.duration) else { continue }
            for track in tracks where track.mediaType == .audio {
                let dest = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try? dest?.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
            }
        }
        guard !composition.tracks.isEmpty else {
            fputs("smriti player: no playable audio in \(directory.path)\n", stderr)
            await MainActor.run { onUnavailable?() }
            return
        }
        let item = AVPlayerItem(asset: composition)
        let total = CMTimeGetSeconds(composition.duration)
        await MainActor.run {
            let player = AVPlayer(playerItem: item)
            self.player = player
            self.durationSeconds = total.isFinite ? total : 0
            self.slider.maxValue = max(1, self.durationSeconds)
            self.updateTimeLabel(0)
            self.setEnabled(true)
            self.timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 4), queue: .main
            ) { [weak self] t in
                guard let self else { return }
                let secs = CMTimeGetSeconds(t)
                self.slider.doubleValue = secs
                self.updateTimeLabel(secs)
                if self.durationSeconds > 0, secs >= self.durationSeconds - 0.1 {
                    self.playButton.title = "▶" // reached the end
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func togglePlay() {
        guard let player else { return }
        if player.rate > 0 {
            player.pause()
            playButton.title = "▶"
        } else {
            if durationSeconds > 0,
               CMTimeGetSeconds(player.currentTime()) >= durationSeconds - 0.1 {
                player.seek(to: .zero) // replay from the start
            }
            player.rate = desiredRate
            playButton.title = "⏸"
        }
    }

    @objc private func sliderMoved() {
        player?.seek(to: CMTime(seconds: slider.doubleValue, preferredTimescale: 600))
    }

    @objc private func cycleRate() {
        desiredRate = desiredRate >= 2.0 ? 1.0 : desiredRate + 0.5
        rateButton.title = desiredRate == 1.0 ? "1×"
            : String(format: "%g×", desiredRate)
        if let player, player.rate > 0 { player.rate = desiredRate }
    }

    private func updateTimeLabel(_ current: Double) {
        func fmt(_ s: Double) -> String {
            let v = max(0, Int(s))
            return String(format: "%d:%02d", v / 60, v % 60)
        }
        timeLabel.stringValue = "\(fmt(current)) / \(fmt(durationSeconds))"
    }
}
