import Cocoa
import ServiceManagement
import CoreGraphics

// MARK: - App State Machine
enum AppState {
    case ready      // Safe to execute video operations
    case paused     // System state unstable, video operations forbidden
}

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    static func main() {
        // Set up uncaught exception handler
        NSSetUncaughtExceptionHandler { exception in
            print("UNCAUGHT EXCEPTION: \(exception.name)")
            print("Reason: \(exception.reason ?? "unknown")")
            print("Call stack:\n\(exception.callStackSymbols.joined(separator: "\n"))")
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    // MARK: - State Machine Properties
    private var appState: AppState = .ready
    private var pendingVideo: VideoAsset?
    private var stateTransitionWorkItem: DispatchWorkItem?

    // MARK: - UI Properties
    var windows: [WallpaperWindow] = []
    var playerViews: [VideoPlayerView] = []
    var statusItem: NSStatusItem!
    var currentVideo: VideoAsset?
    var aboutWindow: NSWindow?
    var selectorWindow: VideoSelectorWindow?

    var launchAtLogin: Bool {
        get {
            return UserDefaults.standard.bool(forKey: "LaunchAtLogin")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "LaunchAtLogin")
            updateLaunchAtLogin(newValue)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup Menu Bar first
        setupMenuBar()

        // Create video selector window (lifecycle = app lifecycle)
        selectorWindow = VideoSelectorWindow()

        // Create windows for all screens
        createWindows()

        // CRITICAL: Register for display reconfiguration BEFORE it happens
        // This is called BEFORE the display actually changes, giving us time to cleanup safely
        CGDisplayRegisterReconfigurationCallback({ (displayID, flags, userInfo) in
            guard let userInfo = userInfo else { return }
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
            appDelegate.handleDisplayReconfiguration(displayID: displayID, flags: flags)
        }, Unmanaged.passUnretained(self).toOpaque())

        // Sleep/wake events
        let sleepWakeEvents: [(Notification.Name, NotificationCenter)] = [
            (NSWorkspace.willSleepNotification, NSWorkspace.shared.notificationCenter),
            (NSWorkspace.didWakeNotification, NSWorkspace.shared.notificationCenter),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.shared.notificationCenter),
            (NSWorkspace.screensDidWakeNotification, NSWorkspace.shared.notificationCenter),
        ]

        for (name, center) in sleepWakeEvents {
            center.addObserver(
                self,
                selector: #selector(handleSystemEvent),
                name: name,
                object: nil
            )
        }

        // Listen for playback failures to auto-recover
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVideoPlaybackFailed),
            name: .videoPlaybackFailed,
            object: nil
        )

        // Listen for video selection from selector window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVideoSelected),
            name: NSNotification.Name("VideoSelected"),
            object: nil
        )

        // Try to resume last played video, otherwise play random
        if let lastVideo = VideoManager.shared.getLastPlayedVideo() {
            playVideo(video: lastVideo)
        } else {
            playRandomVideo()
        }
    }

    /// Handle display reconfiguration - called BEFORE and AFTER display changes
    private func handleDisplayReconfiguration(displayID: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        // BeginConfiguration: Display is ABOUT to change - we must cleanup NOW before it's too late
        if flags.contains(.beginConfigurationFlag) {
            print("Display BEGIN reconfiguration - cleaning up and scheduling recreation")
            // We're on the CoreGraphics callback thread, dispatch to main but DON'T wait
            // Just clear references immediately to prevent any access to invalid display
            DispatchQueue.main.async { [weak self] in
                self?.emergencyCleanup()
                // Schedule recreation immediately after cleanup
                // This ensures we rebuild once after the display configuration completes
                self?.scheduleRecreation()
            }
        }
        // Ignore other callbacks to avoid multiple recreations
    }

    /// Emergency cleanup - just clear all references, don't call any methods
    private func emergencyCleanup() {
        guard appState == .ready else {
            print("Emergency cleanup skipped - already in state: \(appState)")
            return
        }
        appState = .paused
        print("Emergency cleanup - clearing all references (windows: \(windows.count), players: \(playerViews.count))")
        // Just nil out everything - don't call any methods on these objects
        windows = []
        playerViews = []
    }

    /// Schedule recreation after display stabilizes
    private func scheduleRecreation() {
        stateTransitionWorkItem?.cancel()
        print("Scheduling recreation in 2 seconds...")
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else {
                print("Recreation cancelled - self is nil")
                return
            }
            print("Recreation starting - changing state from \(self.appState) to ready")
            self.appState = .ready
            print("Recreating windows and players for \(NSScreen.screens.count) screen(s)")
            self.recreateWindowsInternal()

            print("After recreation - windows: \(self.windows.count), players: \(self.playerViews.count)")

            // CRITICAL: Always resume playback after recreation
            // Priority: pendingVideo > currentVideo > random video
            if let video = self.pendingVideo {
                print("Resuming pending video: \(video.name)")
                self.pendingVideo = nil
                self.playVideoInternal(video: video)
            } else if let video = self.currentVideo {
                print("Resuming current video: \(video.name)")
                self.playVideoInternal(video: video)
            } else {
                // Fallback: if no video info, play random to ensure functionality
                print("No video to resume, playing random")
                if let randomVideo = VideoManager.shared.getRandomVideo() {
                    self.playVideoInternal(video: randomVideo)
                } else {
                    print("ERROR: No videos available to play!")
                }
            }
        }
        stateTransitionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    // MARK: - System Event Handler (Sleep/Wake only)

    /// Handle sleep/wake events
    @objc private func handleSystemEvent(_ notification: Notification) {
        print("System event: \(notification.name.rawValue)")
        emergencyCleanup()
        scheduleRecreation()
    }

    func createWindows() {
        // For initial creation, use the internal method directly
        recreateWindowsInternal()
    }

    /// Internal video play - bypasses state check, used by state machine
    private func playVideoInternal(video: VideoAsset) {
        print("Playing (internal): \(video.name)")
        for playerView in playerViews {
            playerView.play(url: video.url)
        }
        currentVideo = video
        VideoManager.shared.saveLastPlayedVideo(video)
        updateMenu()
    }

    private func recreateWindowsInternal() {
        // Hide and close existing windows
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        playerViews.removeAll()

        // Get all screens
        let screens = NSScreen.screens

        print("Creating windows for \(screens.count) screen(s)")

        // Create a window and player view for each screen
        for (index, screen) in screens.enumerated() {
            print("Creating window \(index + 1) on screen at origin: \(screen.frame.origin), size: \(screen.frame.size)")

            let window = WallpaperWindow(screen: screen)
            guard let contentView = window.contentView else {
                print("ERROR: Failed to get contentView for window \(index + 1)")
                continue
            }

            let playerView = VideoPlayerView(frame: contentView.bounds)
            playerView.autoresizingMask = [.width, .height]
            contentView.addSubview(playerView)

            windows.append(window)
            playerViews.append(playerView)

            // Order window after adding to arrays
            window.orderBack(nil)
            print("Window \(index + 1) created and ordered, playerView bounds: \(playerView.bounds)")
        }

        print("Recreation complete - total windows: \(windows.count), total players: \(playerViews.count)")

        // Update menu immediately to reflect new state
        updateMenu()
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Wallpaper")
        }

        updateMenu()
    }

    func updateMenu() {
        guard let statusItem = statusItem else { return }

        let menu = NSMenu()

        // Check if videos are available
        let videos = VideoManager.shared.getAllVideos()
        let hasVideos = !videos.isEmpty

        // App status indicator
        if !hasVideos {
            let statusItem = NSMenuItem(title: "⚠️ No Aerial Videos Found", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)

            let helpItem = NSMenuItem(title: "How to Download Videos...", action: #selector(showDownloadHelp), keyEquivalent: "")
            menu.addItem(helpItem)
            menu.addItem(NSMenuItem.separator())
        } else if appState == .paused || playerViews.isEmpty {
            let statusItem = NSMenuItem(title: "⏸ Paused (display changing...)", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Play/Pause (disable if not ready)
        let isPlaying = playerViews.first?.isPlaying ?? false
        let playPauseTitle = isPlaying ? "Pause" : "Play"
        let playPauseItem = NSMenuItem(title: playPauseTitle, action: #selector(togglePlayPause), keyEquivalent: " ")
        playPauseItem.isEnabled = (appState == .ready && !playerViews.isEmpty)
        menu.addItem(playPauseItem)

        menu.addItem(NSMenuItem.separator())

        // Current Video Info
        if let current = currentVideo {
            let item = NSMenuItem(title: "Playing: \(current.name)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // Browse Videos Window (only if videos available)
        if hasVideos {
            menu.addItem(NSMenuItem(title: "Browse All Videos...", action: #selector(showVideoSelector), keyEquivalent: "b"))
            menu.addItem(NSMenuItem.separator())
        }

        // Video Selection Submenu (only if videos available)
        if hasVideos {
            let videosMenu = NSMenu()
            let videosItem = NSMenuItem(title: "Select Video", action: nil, keyEquivalent: "")
            videosItem.submenu = videosMenu
            menu.addItem(videosItem)

            for video in videos {
                let item = NSMenuItem(title: video.name, action: #selector(selectVideo(_:)), keyEquivalent: "")
                item.representedObject = video
                if video.url == currentVideo?.url {
                    item.state = .on
                }
                videosMenu.addItem(item)
            }

            // Next Random
            menu.addItem(NSMenuItem(title: "Next Random Wallpaper", action: #selector(playRandomVideo), keyEquivalent: "n"))
        }

        menu.addItem(NSMenuItem.separator())

        // Launch at Login
        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.state = launchAtLogin ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem.separator())

        // Help/About
        menu.addItem(NSMenuItem(title: "About MacLiveWallpaper", action: #selector(showAbout), keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())

        // Quit
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc func togglePlayPause() {
        // Guard: only allow when app is ready and has players
        guard appState == .ready, !playerViews.isEmpty else {
            print("Cannot toggle play/pause - app not ready or no players")
            return
        }

        let isPlaying = playerViews.first?.isPlaying ?? false
        for playerView in playerViews {
            if isPlaying {
                playerView.pause()
            } else {
                playerView.resume()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.updateMenu()
        }
    }

    @objc func selectVideo(_ sender: NSMenuItem) {
        if let video = sender.representedObject as? VideoAsset {
            playVideo(video: video)
        }
    }

    @objc func playRandomVideo() {
        if let video = VideoManager.shared.getRandomVideo() {
            playVideo(video: video)
        }
    }

    @objc private func handleVideoPlaybackFailed(_ notification: Notification) {
        print("Video playback failed, trying another video")
        // Try playing a different random video
        playRandomVideo()
    }

    func playVideo(video: VideoAsset) {
        // State guard - the single checkpoint for all video operations
        guard appState == .ready else {
            print("App not ready, queueing video: \(video.name)")
            pendingVideo = video
            currentVideo = video
            VideoManager.shared.saveLastPlayedVideo(video)
            return
        }

        print("Playing: \(video.name)")
        for playerView in playerViews {
            playerView.play(url: video.url)
        }
        currentVideo = video
        VideoManager.shared.saveLastPlayedVideo(video)
        updateMenu()
    }

    @objc func toggleLaunchAtLogin() {
        launchAtLogin.toggle()
        updateMenu()
    }

    func updateLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                    print("Launch at login enabled")
                } else {
                    try SMAppService.mainApp.unregister()
                    print("Launch at login disabled")
                }
            } catch {
                print("Failed to update launch at login: \(error)")
            }
        } else {
            print("Launch at login requires macOS 13.0 or later")
        }
    }

    @objc func showVideoSelector() {
        // Window created at app launch, just show it
        guard let window = selectorWindow else {
            print("ERROR: Selector window not initialized")
            return
        }

        // Show and bring to front
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func handleVideoSelected(_ notification: Notification) {
        if let video = notification.object as? VideoAsset {
            playVideo(video: video)
        }
    }

    @objc func showDownloadHelp() {
        let alert = NSAlert()
        alert.messageText = "Aerial Videos Not Found"
        alert.informativeText = """
        MacLiveWallpaper requires macOS Aerial screensaver videos to work.

        To download them:
        1. Open System Settings
        2. Go to "Screen Saver"
        3. Select "Aerial" screensaver
        4. Wait for videos to download
        5. Restart MacLiveWallpaper

        Videos are saved to:
        /Library/Application Support/com.apple.idleassetsd/Customer/
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open System Settings")

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            // Open Screen Saver settings
            if let url = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc func showAbout() {
        // If window already exists, just bring it to front
        if let window = aboutWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create about window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About MacLiveWallpaper"
        window.center()

        // Get version from bundle
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

        // Create content view
        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // App icon (if available)
        let iconView = NSImageView(frame: NSRect(x: 150, y: 200, width: 100, height: 100))
        if let icon = NSImage(named: "AppIcon") {
            iconView.image = icon
        } else {
            iconView.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        }
        contentView.addSubview(iconView)

        // App name
        let nameLabel = NSTextField(labelWithString: "MacLiveWallpaper")
        nameLabel.font = NSFont.boldSystemFont(ofSize: 18)
        nameLabel.alignment = .center
        nameLabel.frame = NSRect(x: 50, y: 160, width: 300, height: 25)
        contentView.addSubview(nameLabel)

        // Version
        let versionLabel = NSTextField(labelWithString: "Version \(version) (Build \(build))")
        versionLabel.font = NSFont.systemFont(ofSize: 12)
        versionLabel.alignment = .center
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.frame = NSRect(x: 50, y: 135, width: 300, height: 20)
        contentView.addSubview(versionLabel)

        // Description
        let descLabel = NSTextField(wrappingLabelWithString: "Display macOS Aerial screensavers as live desktop wallpaper on all connected screens.")
        descLabel.font = NSFont.systemFont(ofSize: 13)
        descLabel.alignment = .center
        descLabel.frame = NSRect(x: 50, y: 70, width: 300, height: 60)
        contentView.addSubview(descLabel)

        // Copyright
        let copyrightLabel = NSTextField(labelWithString: "© 2025")
        copyrightLabel.font = NSFont.systemFont(ofSize: 11)
        copyrightLabel.alignment = .center
        copyrightLabel.textColor = .tertiaryLabelColor
        copyrightLabel.frame = NSRect(x: 50, y: 30, width: 300, height: 20)
        contentView.addSubview(copyrightLabel)

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        aboutWindow = window

        // Clear reference when window closes
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.aboutWindow = nil
        }
    }
}
