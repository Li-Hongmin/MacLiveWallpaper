import Cocoa
import AVFoundation

extension Notification.Name {
    static let videoPlaybackFailed = Notification.Name("videoPlaybackFailed")
}

class VideoPlayerView: NSView {
    private var playerLayer: AVPlayerLayer?
    private var playerLooper: AVPlayerLooper?
    private var queuePlayer: AVQueuePlayer?
    private var asset: AVURLAsset?
    private var isUpdatingLayout = false

    // Error observation
    private var errorObserver: NSKeyValueObservation?
    private var statusObserver: NSKeyValueObservation?
    private var itemErrorObserver: NSKeyValueObservation?
    private var itemStatusObserver: NSKeyValueObservation?
    private var hasReportedError = false
    private var watchdogTimer: Timer?
    private var lastPlaybackTime: CMTime = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }

    private func setupLayer() {
        self.wantsLayer = true
        self.layer = CALayer()
        self.layer?.backgroundColor = NSColor.black.cgColor
    }

    func play(url: URL) {
        // Clean up existing player first
        cleanup()
        hasReportedError = false

        // Validate file exists and is readable
        guard FileManager.default.fileExists(atPath: url.path),
              FileManager.default.isReadableFile(atPath: url.path) else {
            print("Video file not accessible: \(url.path)")
            notifyPlaybackFailed()
            return
        }

        // Check file size - skip files smaller than 1MB (likely incomplete)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64,
           size < 1_000_000 {
            print("Video file too small (likely incomplete): \(url.lastPathComponent)")
            notifyPlaybackFailed()
            return
        }

        let videoAsset = AVURLAsset(url: url)
        asset = videoAsset

        // Check if asset is playable asynchronously
        videoAsset.loadValuesAsynchronously(forKeys: ["playable", "duration"]) { [weak self] in
            DispatchQueue.main.async {
                self?.handleAssetLoaded(videoAsset)
            }
        }
    }

    private func handleAssetLoaded(_ videoAsset: AVURLAsset) {
        var error: NSError?
        let playableStatus = videoAsset.statusOfValue(forKey: "playable", error: &error)
        let durationStatus = videoAsset.statusOfValue(forKey: "duration", error: nil)

        // Check if asset loaded successfully
        guard playableStatus == .loaded else {
            print("Video not loadable: \(videoAsset.url.lastPathComponent), status: \(playableStatus.rawValue), error: \(error?.localizedDescription ?? "unknown")")
            notifyPlaybackFailed()
            return
        }

        // Check if asset is playable
        guard videoAsset.isPlayable else {
            print("Video not playable: \(videoAsset.url.lastPathComponent)")
            notifyPlaybackFailed()
            return
        }

        // Check duration is valid (not zero or infinite)
        if durationStatus == .loaded {
            let duration = videoAsset.duration
            if !duration.isValid || duration.seconds <= 0 || duration.seconds.isNaN || duration.seconds.isInfinite {
                print("Video has invalid duration: \(videoAsset.url.lastPathComponent)")
                notifyPlaybackFailed()
                return
            }
        }

        // Start actual playback
        startPlayback(with: videoAsset)
    }

    private func startPlayback(with videoAsset: AVURLAsset) {
        let templateItem = AVPlayerItem(asset: videoAsset)

        // Create queue player
        let player = AVQueuePlayer()
        player.isMuted = false
        queuePlayer = player

        // Setup error observers BEFORE creating looper
        setupObservers(for: player)

        // Create looper with template item
        playerLooper = AVPlayerLooper(player: player, templateItem: templateItem)

        // Create and configure player layer
        let newPlayerLayer = AVPlayerLayer(player: player)
        newPlayerLayer.frame = self.bounds
        newPlayerLayer.videoGravity = .resizeAspectFill
        newPlayerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        playerLayer = newPlayerLayer

        if let layer = self.layer {
            layer.addSublayer(newPlayerLayer)
        }

        player.play()
    }

    private func setupObservers(for player: AVQueuePlayer) {
        // Observe player errors
        errorObserver = player.observe(\.error, options: [.new]) { [weak self] player, _ in
            if let error = player.error {
                print("Player error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.handlePlaybackError()
                }
            }
        }

        // Observe player status
        statusObserver = player.observe(\.status, options: [.new]) { [weak self] player, _ in
            if player.status == .failed {
                print("Player status failed: \(player.error?.localizedDescription ?? "unknown")")
                DispatchQueue.main.async {
                    self?.handlePlaybackError()
                }
            }
        }

        // Observe current item errors
        if let currentItem = player.currentItem {
            setupItemObservers(for: currentItem)
        }

        // Listen for AVPlayerItem failed to play to end
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemFailedToPlayToEnd(_:)),
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: nil
        )

        // Listen for AVPlayerItem stalled
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemStalled(_:)),
            name: .AVPlayerItemPlaybackStalled,
            object: nil
        )

        // Start watchdog timer to detect frozen playback
        startWatchdog()
    }

    private func setupItemObservers(for item: AVPlayerItem) {
        itemErrorObserver = item.observe(\.error, options: [.new]) { [weak self] item, _ in
            if let error = item.error {
                print("PlayerItem error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.handlePlaybackError()
                }
            }
        }

        itemStatusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed {
                print("PlayerItem status failed: \(item.error?.localizedDescription ?? "unknown")")
                DispatchQueue.main.async {
                    self?.handlePlaybackError()
                }
            }
        }
    }

    @objc private func playerItemFailedToPlayToEnd(_ notification: Notification) {
        if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
            print("PlayerItem failed to play to end: \(error.localizedDescription)")
        }
        DispatchQueue.main.async { [weak self] in
            self?.handlePlaybackError()
        }
    }

    @objc private func playerItemStalled(_ notification: Notification) {
        print("PlayerItem playback stalled")
        // Give it a moment to recover, then check if still stalled
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self, let player = self.queuePlayer else { return }
            if player.rate == 0 && player.error == nil {
                print("Player still stalled after 3 seconds, restarting...")
                player.play()
            }
        }
    }

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.checkPlaybackHealth()
        }
    }

    private func checkPlaybackHealth() {
        guard let player = queuePlayer else { return }

        // Check if player has error
        if player.error != nil {
            print("Watchdog detected player error")
            handlePlaybackError()
            return
        }

        // Check if player is supposed to be playing but isn't progressing
        if player.rate > 0 {
            let currentTime = player.currentTime()
            if currentTime == lastPlaybackTime && currentTime.seconds > 0 {
                print("Watchdog detected frozen playback at \(currentTime.seconds)s")
                // Try to recover by seeking slightly
                let newTime = CMTime(seconds: currentTime.seconds + 0.1, preferredTimescale: 600)
                player.seek(to: newTime) { [weak self] _ in
                    self?.queuePlayer?.play()
                }
            }
            lastPlaybackTime = currentTime
        }
    }

    private func handlePlaybackError() {
        guard !hasReportedError else { return }
        hasReportedError = true
        cleanup()
        notifyPlaybackFailed()
    }

    private func notifyPlaybackFailed() {
        NotificationCenter.default.post(name: .videoPlaybackFailed, object: self)
    }

    func cleanup() {
        // Stop watchdog timer
        watchdogTimer?.invalidate()
        watchdogTimer = nil

        // Remove notification observers
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemFailedToPlayToEndTime, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemPlaybackStalled, object: nil)

        // Remove KVO observers
        errorObserver?.invalidate()
        errorObserver = nil
        statusObserver?.invalidate()
        statusObserver = nil
        itemErrorObserver?.invalidate()
        itemErrorObserver = nil
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil

        // 1. Stop playback first
        queuePlayer?.pause()

        // 2. Disable looper BEFORE removing items
        playerLooper?.disableLooping()
        playerLooper = nil

        // 3. Remove items from queue
        queuePlayer?.removeAllItems()

        // 4. Disconnect player from layer before removing
        playerLayer?.player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil

        // 5. Release player and asset
        queuePlayer = nil
        asset = nil

        // Reset state
        lastPlaybackTime = .zero
    }

    var isPlaying: Bool {
        return queuePlayer?.rate != 0 && queuePlayer?.error == nil
    }

    func pause() {
        queuePlayer?.pause()
    }

    func resume() {
        queuePlayer?.play()
    }

    override func layout() {
        super.layout()
        // Guard against recursive layout calls
        guard !isUpdatingLayout else { return }
        isUpdatingLayout = true
        // Update player layer frame without triggering layout recursion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = self.bounds
        CATransaction.commit()
        isUpdatingLayout = false
    }

    deinit {
        cleanup()
    }
}
